-- TALOD - settings: one scrolling page.
--
-- Thirteen sections in the order of the pages, each with a live status line
-- and a link to its page; groups with headings, rarely touched settings last
-- in their group. A search box and three filters list matching settings with
-- a Go button. Modules add their groups with Options.AddSection. Every
-- control that changes a saved setting says where it lives (Options.Bind),
-- so a key has exactly one home. Every control writes straight into the saved
-- data and applies live; no Blizzard templates are needed. The game's
-- Options > AddOns list keeps an entry that opens this page.

local ADDON_NAME, ns = ...
local C = ns.C
local Style = ns.Style
local COLORS, HEX = Style.COLORS, Style.HEX

local Options = {}
ns.Options = Options

local panel, launcher, category
local controls = {}      -- refreshed while the page is shown
local outside = {}       -- widgets built on other pages (refreshed when visible)
local CONTENT_WIDTH = 640
local NAV_WIDTH = 156
local CONTROL_X = 300
local SLIDER_WIDTH = 200

local function db() return ns.DB() end

local function Apply()
    if ns.Refresh then ns.Refresh() end
end

local function AddTooltip(frame, title, text)
    if not text then return end
    frame:HookScript("OnEnter", function(self)
        ns.Tooltip.Text(self, { title, text })
    end)
    frame:HookScript("OnLeave", ns.Tooltip.Hide)
end

---------------------------------------------------------------------------
-- The page's map: sections (in the order of the pages) and every saved
-- setting with its home, for search, the filters and Go.
---------------------------------------------------------------------------
Options.SECTIONS = {
    { key = "general", label = "General", groups = { ns.NAME, "Colors", "Minimap button", "Updates" } },
    { key = "enemies", label = "Enemies", groups = { "Panel", "Nameplates", "Journal", "Census" }, page = "enemies" },
    { key = "alerts", label = "Alerts and safety", groups = { "When to alert", "How to alert", "Stealth", "PvP flag and zones" }, page = "enemies" },
    { key = "fishing", label = "Fishing", groups = { "Logging and HUD", "Warnings", "Safety", "Goals", "Gear and lures" }, page = "fishing" },
    { key = "groups", label = "Groups", groups = { "What to keep" }, page = "groups" },
    { key = "gear", label = "Gear", groups = { "Recording" }, page = "gear" },
    { key = "professions", label = "Professions", groups = { "Recording" }, page = "prof" },
    { key = "gold", label = "Gold", groups = { "Recording" }, page = "gold" },
    { key = "ah", label = "Auction House", groups = { "Prices", "Item tooltips", "At the Auction House" }, page = "ah" },
    { key = "guild", label = "Guild", groups = { "Recruiting", "Chat", "Roster" }, page = "recruit" },
    { key = "audit", label = "Audit", groups = { "Reading", "Flag thresholds" }, page = "audit" },
    { key = "data", label = "Data", groups = { "Cleanup rules", "Memory", "Archive", "Delete data" } },
    { key = "advanced", label = "Advanced", groups = { "Reports", "Whisper pace", "Version check", "Reset" } },
}
-- Where the settings that are not on this page live.
local PLACES = {
    ["recruit/find"] = "Guild > Recruit > Find",
    ["prof/plan"] = "Character > Professions > Plan",
    ["gear/enhance"] = "Character > Gear > Enhance",
    ["members/sharing"] = "Guild > Members > Sharing",
    ["members/roster"] = "Guild > Members > Roster",
    ["members/roster#Activity"] = "Guild > Members > Roster > Activity",
    ["float/mini"] = "Mini recruit window",
    ["float/notice"] = "Recruit-reply notice",
}

Options.SETTINGS = {
    { id = "core.data.cleanAuto", key = "cleanAuto", label = "Clean up automatically", home = "settings/data", type = "preference" },
    { id = "core.data.rule.setAside.on", key = "cleanSetAside", label = "Set-aside entries: use this rule", home = "settings/data", type = "preference" },
    { id = "core.data.rule.setAside.days", key = "cleanSetAsideDays", label = "Set-aside entries: older than (days)", home = "settings/data", type = "preference", fine = true },
    { id = "core.data.rule.priceHistory.on", key = "cleanPriceHistory", label = "Price history: use this rule", home = "settings/data", type = "preference" },
    { id = "core.data.rule.priceHistory.days", key = "cleanPriceHistoryDays", label = "Price history: older than (days)", home = "settings/data", type = "preference", fine = true },
    { id = "core.data.rule.priceUnseen.on", key = "cleanPriceUnseen", label = "Items not seen on the Auction House: use this rule", home = "settings/data", type = "preference" },
    { id = "core.data.rule.priceUnseen.days", key = "cleanPriceUnseenDays", label = "Items not seen on the Auction House: older than (days)", home = "settings/data", type = "preference", fine = true },
    { id = "core.data.rule.guildEvents.on", key = "cleanGuildEvents", label = "Guild event log: use this rule", home = "settings/data", type = "preference" },
    { id = "core.data.rule.guildEvents.days", key = "cleanGuildEventsDays", label = "Guild event log: older than (days)", home = "settings/data", type = "preference", fine = true },
    { id = "core.data.rule.recruitText.on", key = "cleanRecruitText", label = "Recruit messages: use this rule", home = "settings/data", type = "preference" },
    { id = "core.data.rule.recruitText.days", key = "cleanRecruitTextDays", label = "Recruit messages: older than (days)", home = "settings/data", type = "preference", fine = true },
    { id = "core.data.rule.groups.on", key = "cleanGroups", label = "Party and raid history: use this rule", home = "settings/data", type = "preference" },
    { id = "core.data.rule.groups.days", key = "cleanGroupsDays", label = "Party and raid history: older than (days)", home = "settings/data", type = "preference", fine = true },
    { id = "core.data.memoryCapMB", key = "memoryCapMB", label = "Memory cap", home = "settings/data", type = "preference", fine = true },
    { id = "core.data.memoryWarn", key = "memoryWarn", label = "Warn in chat when over the cap", home = "settings/data", type = "preference", notify = true },
    { id = "core.data.cleanArchive", key = "cleanArchive", label = "Move old entries to the archive instead of deleting them", home = "settings/data", type = "preference", fine = true },
    { id = "settings.general.enabled", key = "enabled", label = "Enable " .. ns.NAME, home = "settings/general", type = "preference" },
    { id = "settings.general.colorblind", key = "colorblind", label = "Colorblind-friendly colors", home = "settings/general", type = "preference" },
    { id = "settings.general.minimap", key = "minimapButton", label = "Minimap button", home = "settings/general", type = "preference" },
    { id = "settings.general.versioncheck", key = "versionCheck", label = "Tell me when a newer " .. ns.NAME .. " exists", home = "settings/general", type = "preference", notify = true },
    { id = "settings.general.panelshown", key = "panelShown", label = "Show the panel", home = "settings/enemies", type = "preference", quick = "Home > On screen; minimap Ctrl+left-click; Enemies header" },
    { id = "settings.general.panellocked", key = "panelLocked", label = "Lock position", home = "settings/enemies", type = "preference", quick = "Enemies nearby panel title bar (lock)" },
    { id = "settings.general.panelhideempty", key = "panelHideEmpty", label = "Hide while empty (when locked)", home = "settings/enemies", type = "preference" },
    { id = "settings.general.panelclicktarget", key = "panelClickTarget", label = "Click a row to target", home = "settings/enemies", type = "preference" },
    { id = "settings.general.panelscale", key = "panelScale", label = "Size", home = "settings/enemies", type = "preference" },
    { id = "settings.general.panelrows", key = "panelRows", label = "Rows", home = "settings/enemies", type = "preference", fine = true },
    { id = "settings.general.panelfade", key = "panelFadeSeconds", label = "Keep listed after they leave view", home = "settings/enemies", type = "preference", fine = true },
    { id = "settings.general.paneldetails", key = "panelDetails", label = "Show health, tags, buffs and debuffs", home = "settings/enemies", type = "preference" },
    { id = "settings.general.panelmaxauras", key = "panelMaxAuras", label = "Buff / debuff icons per enemy", home = "settings/enemies", type = "preference", fine = true },
    { id = "settings.general.badges", key = "badgesEnabled", label = "Show badges on enemy nameplates", home = "settings/enemies", type = "preference" },
    { id = "settings.general.targetreadout", key = "targetReadout", label = "Show the target readout", home = "settings/enemies", type = "preference" },
    { id = "settings.general.targetspells", key = "targetSpells", label = "Include your spell ranges", home = "settings/enemies", type = "preference", fine = true },
    { id = "settings.alerts.enabled", key = "alertsEnabled", label = "Enable alerts", home = "settings/alerts", type = "preference", notify = true, quick = "Enemies nearby panel title bar (mute); Home; Enemies header" },
    { id = "settings.alerts.onnameplate", key = "alertOnNameplate", label = "When an enemy nameplate appears", home = "settings/alerts", type = "preference", notify = true },
    { id = "settings.alerts.ontarget", key = "alertOnTarget", label = "When you target an enemy", home = "settings/alerts", type = "preference", notify = true },
    { id = "settings.alerts.onmouseover", key = "alertOnMouseover", label = "When you mouse over an enemy", home = "settings/alerts", type = "preference", notify = true },
    { id = "settings.alerts.minlevelgap", key = "alertMinLevelGap", label = "Only enemies from (levels vs you)", home = "settings/alerts", type = "preference", fine = true, notify = true },
    { id = "settings.alerts.repeat", key = "alertRepeatSeconds", label = "Repeat for the same player after", home = "settings/alerts", type = "preference", fine = true, notify = true },
    { id = "settings.alerts.loudkos", key = "alertLoudKoS", label = "Players on your kill-on-sight list", home = "settings/alerts", type = "preference", notify = true },
    { id = "settings.alerts.loudabove", key = "alertLoudAbove", label = "Enemies this many levels above you", home = "settings/alerts", type = "preference", notify = true },
    { id = "settings.alerts.loudclass.warrior", key = "alertLoudClasses.WARRIOR", label = "Warrior (class-colored name)", home = "settings/alerts", type = "preference", notify = true },
    { id = "settings.alerts.loudclass.rogue", key = "alertLoudClasses.ROGUE", label = "Rogue (class-colored name)", home = "settings/alerts", type = "preference", notify = true },
    { id = "settings.alerts.loudclass.mage", key = "alertLoudClasses.MAGE", label = "Mage (class-colored name)", home = "settings/alerts", type = "preference", notify = true },
    { id = "settings.alerts.loudclass.priest", key = "alertLoudClasses.PRIEST", label = "Priest (class-colored name)", home = "settings/alerts", type = "preference", notify = true },
    { id = "settings.alerts.loudclass.warlock", key = "alertLoudClasses.WARLOCK", label = "Warlock (class-colored name)", home = "settings/alerts", type = "preference", notify = true },
    { id = "settings.alerts.loudclass.hunter", key = "alertLoudClasses.HUNTER", label = "Hunter (class-colored name)", home = "settings/alerts", type = "preference", notify = true },
    { id = "settings.alerts.loudclass.druid", key = "alertLoudClasses.DRUID", label = "Druid (class-colored name)", home = "settings/alerts", type = "preference", notify = true },
    { id = "settings.alerts.loudclass.shaman", key = "alertLoudClasses.SHAMAN", label = "Shaman (class-colored name)", home = "settings/alerts", type = "preference", notify = true },
    { id = "settings.alerts.loudclass.paladin", key = "alertLoudClasses.PALADIN", label = "Paladin (class-colored name)", home = "settings/alerts", type = "preference", notify = true },
    { id = "settings.alerts.centertext", key = "alertCenterText", label = "Center-screen text", home = "settings/alerts", type = "preference", notify = true },
    { id = "settings.alerts.chat", key = "alertChat", label = "Chat line (with zone)", home = "settings/alerts", type = "preference", notify = true },
    { id = "settings.alerts.sound", key = "alertSound", label = "Sound for loud alerts", home = "settings/alerts", type = "preference", notify = true },
    { id = "settings.alerts.soundchoice", key = "alertSoundChoice", label = "Sound", home = "settings/alerts", type = "preference", notify = true },
    { id = "settings.safety.flagindicator", key = "flagIndicator", label = "Always show my PvP flag", home = "settings/alerts", type = "preference", quick = "Home > On screen" },
    { id = "settings.safety.flaglocked", key = "flagLocked", label = "Lock its position", home = "settings/alerts", type = "preference", fine = true },
    { id = "settings.safety.warntarget", key = "flagWarnTarget", label = "Warn when my target would flag me", home = "settings/alerts", type = "preference", notify = true },
    { id = "settings.safety.zonebanner", key = "zoneBanner", label = "Banner when entering contested or enemy territory", home = "settings/alerts", type = "preference", notify = true },
    { id = "settings.stealth.vanish", key = "vanishAlert", label = "Alert when a stealther vanishes nearby", home = "settings/alerts", type = "preference", notify = true },
    { id = "settings.stealth.vanishrange", key = "vanishMaxRange", label = "Only when they were within", home = "settings/alerts", type = "preference", fine = true, notify = true },
    { id = "settings.journal.enabled", key = "journalEnabled", label = "Record enemy players I see", home = "settings/enemies", type = "preference" },
    { id = "settings.journal.max", key = "journalMax", label = "Keep at most", home = "settings/enemies", type = "preference", fine = true },
    { id = "settings.census.enabled", key = "censusEnabled", label = "Log players I see", home = "settings/enemies", type = "preference", quick = "Enemies > Census" },
    { id = "settings.census.allies", key = "censusAllies", label = "Include my own faction", home = "settings/enemies", type = "preference" },
    { id = "settings.census.group", key = "censusGroup", label = "Include my party / raid at their own position", home = "settings/enemies", type = "preference", fine = true },
    { id = "settings.census.skipcapitals", key = "censusSkipCapitals", label = "Only count allies in capital cities", home = "settings/enemies", type = "preference", fine = true },
    { id = "settings.census.enemyseconds", key = "censusEnemySeconds", label = "Enemy: one point every", home = "settings/enemies", type = "preference", fine = true },
    { id = "settings.census.allyseconds", key = "censusAllySeconds", label = "Ally: one point every", home = "settings/enemies", type = "preference", fine = true },
    { id = "settings.census.maxpoints", key = "censusMaxPoints", label = "Keep at most", home = "settings/enemies", type = "preference", fine = true },
    { id = "char.set.gear.gearEnabled", key = "gearEnabled", label = "Track my gear and stats", home = "settings/gear", type = "preference" },
    { id = "char.set.gear.gearSources", key = "gearSources", label = "Note where new items came from", home = "settings/gear", type = "preference" },
    { id = "char.set.skills.skillsEnabled", key = "skillsEnabled", label = "Track my skills", home = "settings/professions", type = "preference" },
    { id = "char.set.skills.profPlanPatterns", key = "profPlanPatterns", label = "Plan with patterns too", home = "prof/plan", type = "tool option" },
    { id = "char.set.skills.profPlanBags", key = "profPlanBags", label = "Count my bags and bank", home = "prof/plan", type = "tool option" },
    { id = "char.set.skills.auctionPrices", key = "auctionPrices", label = "Log the prices I see at the Auction House", home = "settings/ah", type = "preference" },
    { id = "char.set.skills.tooltipPrices", key = "tooltipPrices", label = "Show my Auction House price on item tooltips", home = "settings/ah", type = "preference" },
    { id = "char.set.skills.tooltipMovement", key = "tooltipMovement", label = "Show on item tooltips whether it sells", home = "settings/ah", type = "preference" },
    { id = "char.set.skills.tooltipGraph", key = "tooltipGraph", label = "Price graph under item tooltips at the Auction House", home = "settings/ah", type = "preference" },
    { id = "char.set.skills.tooltipGraphAlways", key = "tooltipGraphAlways", label = "... everywhere, not only at the Auction House", home = "settings/ah", type = "preference", fine = true },
    { id = "char.set.skills.ahLookupClick", key = "ahLookupClick", label = "Click an item in the Market window: search it on the open Auction House", home = "settings/ah", type = "preference" },
    { id = "char.set.skills.ahHelper", key = "ahHelper", label = "Scan panel next to the Auction House", home = "settings/ah", type = "preference", quick = "Home > On screen; Auction House header" },
    { id = "char.set.skills.deskMinProfit", key = "deskMinProfit", label = "Auction desk: resets worth showing from", home = "settings/ah", type = "preference", fine = true },
    { id = "char.set.skills.craftLogEnabled", key = "craftLogEnabled", label = "Log my crafts", home = "settings/professions", type = "preference" },
    { id = "char.setting.profPlanTargets", key = "profPlanTargets", label = "Target skill per profession", home = "prof/plan", type = "tool option" },
    { id = "char.setting.profPlanFrom", key = "profPlanFrom", label = "Start skill set by hand", home = "prof/plan", type = "tool option" },
    { id = "char.setting.profPlanResale", key = "profPlanResale", label = "Resale", home = "prof/plan", type = "tool option" },
    { id = "char.setting.profPlanExcluded", key = "profPlanExcluded", label = "Excluded recipes", home = "prof/plan", type = "tool option" },
    { id = "char.setting.enhance", key = "enhanceHidden / enhanceMineOnly", label = "Enhance profession filter", home = "gear/enhance", type = "tool option" },
    { id = "econ.settings.enabled", key = "economyEnabled", label = "Track my money and trades", home = "settings/gold", type = "preference" },
    { id = "fish.settings.fishingEnabled", key = "fishingEnabled", label = "Log my fishing", home = "settings/fishing", type = "preference" },
    { id = "fish.settings.fishHud", key = "fishHud", label = "Show the fishing HUD", home = "settings/fishing", type = "preference", quick = "Home > On screen; Fishing header" },
    { id = "fish.settings.fishHudLocked", key = "fishHudLocked", label = "Lock the fishing HUD", home = "settings/fishing", type = "preference", quick = "Fishing HUD title bar (lock)" },
    { id = "fish.settings.fishAlerts", key = "fishAlerts", label = "Warn me", home = "settings/fishing", type = "preference", notify = true },
    { id = "fish.settings.fishBagWarn", key = "fishBagWarn", label = "Bags almost full at (N free)", home = "settings/fishing", type = "preference", fine = true, notify = true },
    { id = "fish.settings.fishEnemySound", key = "fishEnemySound", label = "Sound for every enemy player while fishing", home = "settings/fishing", type = "preference", notify = true },
    { id = "fish.settings.btn-autoloot", key = "fishAutoLoot", label = "Auto loot while fishing", home = "settings/fishing", type = "preference", quick = "Fishing header" },
    { id = "fish.settings.btn-splash", key = "fishLoudSplash", label = "Loud splash while fishing", home = "settings/fishing", type = "preference", quick = "Fishing header" },
    { id = "fish.settings.fishSessionSummary", key = "fishSessionSummary", label = "Chat summary when a session ends", home = "settings/fishing", type = "preference", notify = true },
    { id = "fish.settings.fishMaxCasts", key = "fishMaxCasts", label = "Keep at most (N casts)", home = "settings/fishing", type = "preference", fine = true },
    { id = "fish.settings.fishPoleWarn", key = "fishPoleWarn", label = "Warn me: fishing pole in my hands with an enemy in view", home = "settings/fishing", type = "preference", notify = true },
    { id = "fish.settings.fishPoleWarnRepeat", key = "fishPoleWarnRepeat", label = "Same player again after (s)", home = "settings/fishing", type = "preference", fine = true, notify = true },
    { id = "fish.settings.fishTargetAlert", key = "fishTargetAlert", label = "Warn me when an enemy player targets me while fishing", home = "settings/fishing", type = "preference", notify = true },
    { id = "fish.settings.fishNearestRow", key = "fishNearestRow", label = "Show the nearest player's range on the HUD", home = "settings/fishing", type = "preference" },
    { id = "fish.settings.fishSwapButton", key = "fishSwapButton", label = "Show a weapon swap button while the fishing pole is equipped", home = "settings/fishing", type = "preference" },
    { id = "fish.settings.fishSwapRow", key = "fishSwapRow", label = "Click the HUD's Weapon line to equip my weapon", home = "settings/fishing", type = "preference" },
    { id = "fish.settings.fishZoneHud", key = "fishZoneHud", label = "Zone fishing level (on the HUD)", home = "settings/fishing", type = "preference" },
    { id = "fish.settings.fishExtravaganza", key = "fishExtravaganza", label = "Stranglethorn Fishing Extravaganza (on the HUD)", home = "settings/fishing", type = "preference" },
    { id = "fish.settings.fishExtravaganzaChat", key = "fishExtravaganzaChat", label = "Remind me in chat", home = "settings/fishing", type = "preference", notify = true },
    { id = "fish.settings.fishGoalsAnnounce", key = "fishGoalsAnnounce", label = "Chat line for a first catch", home = "settings/fishing", type = "preference", notify = true },
    { id = "fish.settings.fishGearShow", key = "fishGearShow", label = "Show fishing gear and lures", home = "settings/fishing", type = "preference" },
    { id = "fish.settings.fishGearWarn", key = "fishGearWarn", label = "Warn when better fishing gear is in my bags", home = "settings/fishing", type = "preference", notify = true },
    { id = "fish.settings.fishLureButton", key = "fishLureButton", label = "Apply-lure button under the HUD", home = "settings/fishing", type = "preference" },
    { id = "fish.settings.fishLureAgain", key = "fishLureAgain", label = "Click the HUD's Lure line to use the same lure again", home = "settings/fishing", type = "preference" },
    { id = "fish.settings.fishLurePrefer", key = "fishLurePrefer", label = "The button uses: my best lure / my smallest lure", home = "settings/fishing", type = "preference", fine = true },
    { id = "fish.settings.fishPlanTag", key = "fishPlanTag", label = "Tag fish my profession plan needs", home = "settings/fishing", type = "preference" },
    { id = "fish.settings.fishPoolTag", key = "fishPoolTag", label = "Guess pool casts from the pool tooltip", home = "settings/fishing", type = "preference", fine = true },
    { id = "guild.sharing.recruiting", key = "guildShare.recruiting", label = "My recruiting  (Yes / No)", home = "members/sharing", type = "consent" },
    { id = "guild.sharing.alts", key = "guildShare.alts", label = "My other characters  (Yes / No)", home = "members/sharing", type = "consent" },
    { id = "guild.sharing.prof", key = "guildShare.prof", label = "Level and professions  (Yes / No)", home = "members/sharing", type = "consent" },
    { id = "guild.sharing.activity", key = "guildShare.activity", label = "Play time  (Yes / No)", home = "members/sharing", type = "consent" },
    { id = "guild.sharing.stats", key = "guildShare.stats", label = "Gold and activity statistics  (Yes / No)", home = "members/sharing", type = "consent" },
    { id = "guild.set.guildRecruitScan", key = "guildRecruitScan", label = "Look for players without a guild near me", home = "settings/guild", type = "preference" },
    { id = "guild.set.guildMiniShown", key = "guildMiniShown", label = "Show the mini recruit window", home = "settings/guild", type = "preference", quick = "Home > On screen; Recruit header; the mini window's x" },
    { id = "guild.set.guildWhisper", key = "guildWhisper", label = "Whisper my message before the invite / when I click a player (Forever)", home = "recruit/find", type = "tool option" },
    { id = "guild.set.guildDelayedInvite", key = "guildDelayedInvite", label = "Delayed invite: click again to invite", home = "recruit/find", type = "tool option" },
    { id = "guild.set.guildHandsFree", key = "guildHandsFree", label = "Hands Free: a click on the open world is my next recruit click", home = "recruit/find", type = "tool option" },
    { id = "guild.set.guildHandsFreeKeys", key = "guildHandsFreeKeys", label = "Hands Free: my move and jump keys count too", home = "settings/guild", type = "preference", fine = true },
    { id = "guild.set.guildWhoZone", key = "guildWhoZone", label = "/who searches only my current zone", home = "recruit/find", type = "tool option" },
    { id = "guild.set.guildHideChat", key = "guildHideChat", label = "Keep recruiting chatter out of chat", home = "settings/guild", type = "preference", notify = true },
    { id = "guild.set.guildColorJoin", key = "guildColorJoin", label = "Color \"has joined the guild\" lines in chat", home = "settings/guild", type = "preference", fine = true, notify = true },
    { id = "guild.set.guildColorGuilded", key = "guildColorGuilded", label = "Color \"is already in a guild\" lines in chat", home = "settings/guild", type = "preference", fine = true, notify = true },
    { id = "guild.set.guildReplyNotice", key = "guildReplyNotice", label = "Show a notice when a recruit whispers me", home = "settings/guild", type = "preference", notify = true },
    { id = "guild.set.guildRecruitMinLevel", key = "guildRecruitMinLevel", label = "Lowest level", home = "recruit/find", type = "tool option" },
    { id = "guild.set.guildRecruitMaxLevel", key = "guildRecruitMaxLevel", label = "Highest level", home = "recruit/find", type = "tool option" },
    { id = "guild.set.guildReinviteDays", key = "guildReinviteDays", label = "Offer again after (days)", home = "settings/guild", type = "preference", fine = true },
    { id = "guild.set.guildInactiveDays", key = "guildInactiveDays", label = "Inactive after (days offline)", home = "settings/guild", type = "preference", fine = true },
    { id = "guild.key.guildRecruitHideClass", key = "guildRecruitHideClass", label = "Recruit list: classes hidden", home = "recruit/find", type = "tool option" },
    { id = "guild.key.guildRecruitHideScript", key = "guildRecruitHideScript", label = "Recruit list: name alphabets hidden", home = "recruit/find", type = "tool option" },
    { id = "guild.key.guildMessages", key = "guildMessages", label = "Recruit whisper messages", home = "recruit/find", type = "tool option" },
    { id = "guild.key.guildMessageIndex", key = "guildMessageIndex", label = "Recruit whisper message in use", home = "recruit/find", type = "tool option" },
    { id = "guild.key.guildChatDays", key = "guildChatDays", label = "Activity: days shown", home = "members/roster#Activity", type = "tool option" },
    { id = "guild.key.guildShare", key = "guildShare", label = "What I share with officers", home = "members/sharing", type = "consent" },
    { id = "guild.key.guildMiniPos", key = "guildMiniPos", label = "Mini recruit window position", home = "float/mini", type = "internal" },
    { id = "guild.key.guildNoticePos", key = "guildNoticePos", label = "Recruit-reply notice position", home = "float/notice", type = "internal" },
    { id = "guild.key.guildRefused", key = "guildRefused", label = "Players who refused the guild", home = "members/roster", type = "internal" },
    { id = "audgrp.set.auditOnInspect", key = "auditOnInspect", label = "Read a player's statistics when I inspect them", home = "settings/audit", type = "preference" },
    { id = "audgrp.set.auditGapGold", key = "auditGapGold", label = "Peak above recorded income", home = "settings/audit", type = "preference", fine = true },
    { id = "audgrp.set.auditOtherGold", key = "auditOtherGold", label = "Income from other sources", home = "settings/audit", type = "preference", fine = true },
    { id = "audgrp.set.auditOtherShare", key = "auditOtherShare", label = "... and at least this share of income", home = "settings/audit", type = "preference", fine = true },
    { id = "audgrp.set.auditJumpGold", key = "auditJumpGold", label = "Sudden gold between two looks", home = "settings/audit", type = "preference", fine = true },
    { id = "audgrp.set.auditLevelRule", key = "auditLevelRule", label = "Flag peak gold high for the level (below 55)", home = "settings/audit", type = "preference", fine = true },
    { id = "audgrp.gset.groupsLog", key = "groupsLog", label = "Keep a record of my parties and raids", home = "settings/groups", type = "preference" },
    { id = "audgrp.gset.groupsChat", key = "groupsChat", label = "Keep the group's chat (party, raid, raid warnings, instance)", home = "settings/groups", type = "preference" },
    { id = "audgrp.gset.groupsLoot", key = "groupsLoot", label = "Keep the loot the group's loot messages show", home = "settings/groups", type = "preference" },
    { id = "audgrp.gset.groupsLootQuality", key = "groupsLootQuality", label = "Loot to keep", home = "settings/groups", type = "preference", fine = true },
    { id = "settings.unreachable.journalMergeMinutes", key = "journalMergeMinutes", label = "One visit if seen again within", home = "settings/enemies", type = "preference", fine = true },
    { id = "settings.general.classiclook", key = "classicLook", label = "Classic look", home = "settings/general", type = "preference" },
    { id = "settings.general.textsize", key = "textSize", label = "Text size", home = "settings/general", type = "preference" },
    { id = "settings.general.compactrows", key = "compactRows", label = "Compact rows", home = "settings/general", type = "preference" },
}

local byKey, sectionOf = {}, {}
for _, row in ipairs(Options.SETTINGS) do byKey[row.key] = byKey[row.key] or row end
for _, sec in ipairs(Options.SECTIONS) do sectionOf[sec.key] = sec end

function Options.Setting(key) return byKey[key] end
function Options.Section(key) return sectionOf[key] end

---------------------------------------------------------------------------
-- Bindings: where each control that changes a saved setting lives.
-- kind: "home" (its one place), "tool" (on its page), "consent", "quick"
-- (a quick switch on the thing it controls). where: a route such as
-- settings/enemies, recruit/find or float/panel.
---------------------------------------------------------------------------
local bindings = {}
function Options.Bind(key, kind, where)
    if type(key) ~= "string" or type(where) ~= "string" then return end
    bindings[key] = bindings[key] or {}
    bindings[key][where] = kind or "home"
end
function Options.Bindings() return bindings end

---------------------------------------------------------------------------
-- Values and defaults ("a.b" = field b of the table a)
---------------------------------------------------------------------------
local function Split(key)
    local a, b = key:match("^([^%.]+)%.(.+)$")
    return a or key, b
end

local function Value(key)
    local a, b = Split(key)
    local v = db()[a]
    if b then return type(v) == "table" and v[b] or nil end
    return v
end

-- Keys with no entry in ns.defaults that Settings still compares and resets.
-- cleanAuto is decided by Store.Load (on for a first install, off after an
-- update), so it has no default there; here it is what a new install gets.
local SETTINGS_DEFAULTS = { cleanAuto = true }

local function Default(key)
    local a, b = Split(key)
    local d = ns.defaults[a]
    if d == nil and not b then d = SETTINGS_DEFAULTS[a] end
    if b then return type(d) == "table" and d[b] or nil end
    return d
end

-- Tables (lists, per-profession filters) are never "changed": they are data.
local function Same(v, d)
    if type(v) == "table" or type(d) == "table" then return true end
    if type(v) == "number" and type(d) == "number" then return math.abs(v - d) < 1e-6 end
    if v == nil or d == nil then
        if type(v) == "number" or type(d) == "number" or type(v) == "string" or type(d) == "string" then return true end
        return (v and true or false) == (d and true or false)
    end
    if type(v) == "boolean" or type(d) == "boolean" then return (v and true or false) == (d and true or false) end
    return v == d
end

function Options.IsChanged(key) return not Same(Value(key), Default(key)) end
Options.Value, Options.Default = Value, Default

local function ValueText(v)
    if type(v) == "boolean" or v == nil then return v and "on" or "off" end
    if type(v) == "number" then return (v % 1 == 0) and tostring(v) or string.format("%.1f", v) end
    return tostring(v)
end

---------------------------------------------------------------------------
-- Rows: every setting control on this page, for Go, the changed mark and
-- reset. help[key] = its tooltip, for search.
---------------------------------------------------------------------------
local rows, help = {}, {}
local building            -- the section being built (Where's default)

local function Where(opts)
    if opts and opts.where then return opts.where end
    return building and ("settings/" .. building) or nil
end

function Options.ResetKey(key)
    local d = Default(key)
    local row = rows[key]
    if row and row.set then
        row.set(d)
    else
        local a, b = Split(key)
        if b then
            if type(db()[a]) == "table" then db()[a][b] = d end
        else
            db()[a] = d
        end
    end
    if row and row.onChange then row.onChange(d) end
    Apply()
    if Options.Refresh then Options.Refresh() end
end

-- The parts of a settings row around its control: the changed mark (an accent
-- square before the label), the reset glyph at the right edge, a dimmer label
-- for fine-tuning and the "quick switch" tag. Outside this page (a control on
-- a page) only the binding is kept.
local function Decorate(parent, y, key, label, markX, opts, tooltip, height)
    opts = opts or {}
    local where = Where(opts)
    if where then
        local kind = opts.kind or (where:find("^settings/") and "home" or "tool")
        Options.Bind(key, kind, where)
    end
    if tooltip and not help[key] then help[key] = tooltip end
    local s = byKey[key]
    local fine = opts.fine
    if fine == nil then fine = s and s.fine end
    if fine and label then label:SetTextColor(COLORS.t3[1], COLORS.t3[2], COLORS.t3[3]) end
    if not building or opts.where then return nil end

    local row = { key = key, parent = parent, y = y, section = building, set = opts.set, onChange = opts.onChange }
    if not rows[key] then rows[key] = row end
    height = height or 24
    local mark = Style.Texture(parent, "ARTWORK", COLORS.accent)
    mark:SetSize(5, 5)
    mark:SetPoint("TOPLEFT", markX or 10, y - math.floor(height / 2) + 2)
    mark:Hide()
    local reset
    if not opts.noReset then
        reset = Style.IconButton(parent, "reset", function() Options.ResetKey(key) end, function()
            return { "Back to default", "Default: " .. ValueText(Default(key)) .. "." }
        end, { small = true })
        reset:SetPoint("TOPLEFT", CONTENT_WIDTH - 32, y - math.floor((height - 18) / 2))
        reset:Hide()
    end
    if s and s.quick and s.quick ~= "" and label then
        local tag = Style.Tag(parent)
        tag:Set("quick switch", "plain", false)
        tag:SetPoint("LEFT", label, "RIGHT", 8, 0)
        if tag.EnableMouse then tag:EnableMouse(true) end
        tag:SetScript("OnEnter", function(self) ns.Tooltip.Text(self, { "Quick switch", "Also: " .. s.quick .. "." }) end)
        tag:SetScript("OnLeave", function() ns.Tooltip.Hide() end)
        row.tag = tag
    end
    controls[#controls + 1] = { Refresh = function()
        local changed = Options.IsChanged(key)
        mark:SetShown(changed)
        if reset then reset:SetShown(changed) end
    end }
    row.mark, row.reset = mark, reset
    return row
end

local function Track(control, opts)
    if building and not (opts and opts.where) then
        controls[#controls + 1] = control
    else
        outside[#outside + 1] = control
    end
end

-- "Also: ..." for a key with a quick switch, after its own tooltip.
local function TooltipLines(label, tooltip, key)
    local lines = { label }
    if tooltip then lines[#lines + 1] = tooltip end
    local s = byKey[key]
    if s and s.quick and s.quick ~= "" then lines[#lines + 1] = "Quick switch: " .. s.quick .. "." end
    return lines
end

---------------------------------------------------------------------------
-- Widgets
---------------------------------------------------------------------------
local function Header(parent, y, text, subtitle)
    y = y - 4
    local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    fs:SetPoint("TOPLEFT", 16, y)
    fs:SetText(text)
    local line = Style.HLine(parent)
    line:SetPoint("TOPLEFT", fs, "BOTTOMLEFT", 0, -5)
    line:SetPoint("RIGHT", parent, "LEFT", CONTENT_WIDTH - 16, 0)
    y = y - 26
    if subtitle then
        local sub = parent:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
        sub:SetPoint("TOPLEFT", 18, y)
        sub:SetWidth(CONTENT_WIDTH - 40)
        sub:SetJustifyH("LEFT")
        sub:SetText(subtitle)
        y = y - math.max(14, sub:GetStringHeight() or 14) - 6
    end
    return y
end

-- The small heading over the rarely touched settings at the end of a group.
local function Fine(parent, y)
    local fs = Style.Text(parent, "label")
    fs:SetPoint("TOPLEFT", 22, y - 2)
    fs:SetText("Fine-tuning")
    fs:SetTextColor(COLORS.t4[1], COLORS.t4[2], COLORS.t4[3])
    return y - 18
end

local function Hover(frame, on)
    local c = on and COLORS.accent or COLORS.border
    if frame.SetBorderColor then frame:SetBorderColor(c[1], c[2], c[3], on and 0.9 or 1) end
end

-- Flat checkbox: a bordered box with an accent square when on; the label
-- is part of the click area.
-- tbl (optional): a subtable of the saved data the key lives in, e.g. the
-- per-class alert switches.
-- opts (optional): where / kind (the binding, default: this page's section),
-- fine, set = fn(on) instead of writing the key, get = fn() -> on,
-- onChange = fn(on) after a change, noReset.
local function Checkbox(parent, y, key, label, tooltip, x, tbl, opts)
    opts = opts or {}
    local full = tbl and (tbl .. "." .. key) or key
    local cb = CreateFrame("CheckButton", nil, parent)
    cb:SetSize(18, 18)
    cb:SetPoint("TOPLEFT", (x or 16) + 4, y - 3)
    local bg = Style.Texture(cb, "BACKGROUND", COLORS.button)
    bg:SetAllPoints()
    Style.Border(cb, COLORS.border)
    cb.mark = Style.Texture(cb, "ARTWORK", COLORS.accent)
    cb.mark:SetPoint("TOPLEFT", 4, -4)
    cb.mark:SetPoint("BOTTOMRIGHT", -4, 4)
    local fs = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    fs:SetPoint("LEFT", cb, "RIGHT", 8, 0)
    fs:SetText(label)
    cb.label = fs
    cb:SetHitRectInsets(0, -math.min(260, (fs:GetStringWidth() or 120) + 10), 0, 0)

    local function Get()
        if opts.get then return opts.get() end
        local t = tbl and db()[tbl] or db()
        return type(t) == "table" and t[key] or nil
    end
    cb:SetScript("OnClick", function(self)
        local on = self:GetChecked() and true or false
        if opts.set then
            opts.set(on)
        elseif tbl then
            if type(db()[tbl]) ~= "table" then db()[tbl] = {} end
            db()[tbl][key] = on or nil
        else
            db()[key] = on
        end
        self.mark:SetShown(on)
        if opts.onChange then opts.onChange(on) end
        Apply()
    end)
    cb:SetScript("OnEnter", function(self)
        Hover(self, true)
        if tooltip or (byKey[full] and byKey[full].quick) then ns.Tooltip.Text(self, TooltipLines(label, tooltip, full)) end
    end)
    cb:SetScript("OnLeave", function(self) Hover(self, false) ns.Tooltip.Hide() end)
    cb.Refresh = function(self)
        local on = Get() and true or false
        self:SetChecked(on)
        self.mark:SetShown(on)
    end
    Track(cb, opts)
    if tbl and opts.noReset == nil then opts.noReset = true end
    cb.row = Decorate(parent, y, full, fs, (x or 16) - 4, opts, tooltip, 24)
    if cb.row then cb.row.control = cb end
    return y - 28, cb
end

-- Flat slider: a thin track filled up to the value, a small accent thumb.
-- opts as for Checkbox (where, kind, fine, set, get, onChange).
local function Slider(parent, y, key, label, minValue, maxValue, step, format, tooltip, opts)
    opts = opts or {}
    local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    fs:SetPoint("TOPLEFT", 22, y - 2)
    fs:SetText(label)

    local s = CreateFrame("Slider", nil, parent)
    s:SetOrientation("HORIZONTAL")
    s:SetSize(SLIDER_WIDTH, 16)
    s:SetPoint("TOPLEFT", CONTROL_X, y)
    s:SetHitRectInsets(0, 0, -6, -6)
    local track = Style.Texture(s, "BACKGROUND", COLORS.track)
    track:SetHeight(4)
    track:SetPoint("LEFT")
    track:SetPoint("RIGHT")
    local fill = Style.Texture(s, "ARTWORK", COLORS.bar)
    fill:SetHeight(4)
    fill:SetPoint("LEFT")
    local thumb = s:CreateTexture(nil, "OVERLAY")
    thumb:SetTexture(Style.WHITE)
    thumb:SetSize(8, 16)
    Style.Fill(thumb, COLORS.accent)
    if not pcall(s.SetThumbTexture, s, thumb) then
        pcall(s.SetThumbTexture, s, "Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    end
    s:SetMinMaxValues(minValue, maxValue)
    s:SetValueStep(step)
    if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
    s:EnableMouseWheel(true)

    local valueText = s:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    valueText:SetPoint("LEFT", s, "RIGHT", 12, 0)

    local function Show(value)
        valueText:SetText(type(format) == "function" and format(value) or string.format(format or "%s", value))
        local frac = (maxValue > minValue) and (value - minValue) / (maxValue - minValue) or 0
        fill:SetWidth(math.max(1, frac * SLIDER_WIDTH))
    end

    local function Get()
        if opts.get then return opts.get() end
        return db()[key]
    end
    local refreshing = false
    s:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value / step + 0.5) * step
        Show(value)
        if refreshing then return end
        if Get() ~= value then
            if opts.set then opts.set(value) else db()[key] = value end
            if opts.onChange then opts.onChange(value) end
            Apply()
        end
    end)
    s:SetScript("OnMouseWheel", function(self, delta)
        self:SetValue(math.max(minValue, math.min(maxValue, self:GetValue() + delta * step)))
    end)
    s:SetScript("OnEnter", function(self)
        if tooltip or (byKey[key] and byKey[key].quick) then ns.Tooltip.Text(self, TooltipLines(label, tooltip, key)) end
    end)
    s:SetScript("OnLeave", function() ns.Tooltip.Hide() end)
    s.Refresh = function(self)
        refreshing = true
        local value = Get() or minValue
        self:SetValue(value)
        Show(value)
        refreshing = false
    end
    s.label = fs
    Track(s, opts)
    s.row = Decorate(parent, y, key, fs, 12, opts, tooltip, 20)
    if s.row then s.row.control = s end
    return y - 32, s
end

local function Button(parent, y, text, width, onClick, tooltip, x, opts)
    local b = Style.Button(parent, text, width or 160, onClick, tooltip, opts)
    b:SetPoint("TOPLEFT", x or 22, y)
    return y - 28, b
end

-- A button that cycles through a fixed list of choices (UIDropDownMenu is
-- deprecated on the modern engine). opts as for Checkbox.
local function Cycle(parent, y, key, label, choices, tooltip, opts)
    opts = opts or {}
    local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    fs:SetPoint("TOPLEFT", 22, y - 4)
    fs:SetText(label)

    local _, b = Button(parent, y, "", SLIDER_WIDTH, nil, (tooltip and (tooltip .. "\n") or "") .. "Left-click: next. Right-click: previous. Arrow: pick from a list.", CONTROL_X)
    local function List()
        if type(choices) == "function" then return choices() end
        return choices
    end
    local function Get()
        if opts.get then return opts.get() end
        return db()[key]
    end
    local function Index()
        local cur = Get()
        for i, choice in ipairs(List()) do
            if choice.value == cur then return i end
        end
        return 1
    end
    local function SetLabel()
        b:SetLabel((List()[Index()] or { label = "?" }).label .. "  >")
    end
    local function Pick(value)
        if opts.set then opts.set(value) else db()[key] = value end
        SetLabel()
        if opts.onChange then opts.onChange(value) end
        Apply()
    end
    b:SetScript("OnClick", function(_, mouseButton)
        local list = List()
        local i = Index() + (mouseButton == "RightButton" and -1 or 1)
        if i > #list then i = 1 elseif i < 1 then i = #list end
        Pick(list[i].value)
    end)
    Style.AttachDropdown(b, function()
        local out, cur = {}, Get()
        for _, choice in ipairs(List()) do
            out[#out + 1] = { label = choice.label, selected = choice.value == cur, pick = function() Pick(choice.value) end }
        end
        return out
    end)
    b.Refresh = SetLabel
    b.label = fs
    Track(b, opts)
    b.row = Decorate(parent, y, key, fs, 12, opts, tooltip, 22)
    if b.row then b.row.control = b end
    return y - 30, b
end

local function Paragraph(parent, y, text, template)
    local fs = parent:CreateFontString(nil, "ARTWORK", template or "GameFontHighlight")
    fs:SetPoint("TOPLEFT", 16, y)
    fs:SetWidth(CONTENT_WIDTH - 32)
    fs:SetJustifyH("LEFT")
    fs:SetText(text)
    return y - (fs:GetStringHeight() or 14) - 12, fs
end

-- A text block whose content is recomputed on every refresh.
local function LiveText(parent, y, height, compute)
    local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", 22, y)
    fs:SetWidth(CONTENT_WIDTH - 44)
    fs:SetJustifyH("LEFT")
    fs.Refresh = function(self) self:SetText(compute()) end
    Track(fs)
    return y - height, fs
end

Options.Widgets = {
    Header = Header, Checkbox = Checkbox, Slider = Slider, Button = Button, Cycle = Cycle, Fine = Fine,
    Paragraph = Paragraph, LiveText = LiveText, AddTooltip = AddTooltip, CONTENT_WIDTH = CONTENT_WIDTH,
    CONTROL_X = CONTROL_X,
}
function Options.Widgets.Track(control) Track(control) end
function Options.Apply() Apply() end

local function Signed(v) return (v > 0 and "+" or "") .. v end

---------------------------------------------------------------------------
-- Sections: modules add groups with Options.AddSection at file load.
--   Options.AddSection(sectionKey, { status = fn() -> text,
--       groups = { { label = "Group", build = fn(parent, y) -> y } } })
-- Builders of the same group run in the order they were added; groups follow
-- the section's list, others after it.
---------------------------------------------------------------------------
local sectionDefs = {}
local built = false

local function SectionDef(key)
    local d = sectionDefs[key]
    if not d then
        d = { groups = {}, byLabel = {} }
        sectionDefs[key] = d
    end
    return d
end

function Options.AddSection(key, def)
    local d = SectionDef(key)
    def = def or {}
    if def.status then d.status = def.status end
    for _, g in ipairs(def.groups or {}) do
        local label = g.label or g[1] or ""
        local group = d.byLabel[label]
        if not group then
            group = { label = label, builds = {} }
            d.byLabel[label] = group
            d.groups[#d.groups + 1] = group
        end
        group.builds[#group.builds + 1] = g.build or g[2]
    end
end

local function OrderedGroups(sec)
    local d = sectionDefs[sec.key]
    if not d then return {} end
    local out, used = {}, {}
    for _, label in ipairs(sec.groups or {}) do
        if d.byLabel[label] then out[#out + 1] = d.byLabel[label] used[label] = true end
    end
    for _, group in ipairs(d.groups) do
        if not used[group.label] then out[#out + 1] = group end
    end
    return out
end

-- Old tabs (Options.AddTab): their pages become groups of the matching
-- section; a page's build(parent) -> height draws into a frame of its own.
local OLD_TABS = { General = "general", Alerts = "alerts", Safety = "alerts", Stealth = "alerts", Journal = "enemies",
    Census = "enemies", Character = "gear", Fishing = "fishing", Groups = "groups", Guild = "guild", Audit = "audit",
    Data = "data", Advanced = "advanced", Economy = "gold", Skills = "professions" }

function Options.AddTab(def)
    local key = OLD_TABS[def.label] or (sectionOf[(def.label or ""):lower()] and def.label:lower()) or "advanced"
    local groups = {}
    for _, page in ipairs(def.pages or {}) do
        local build = page.build
        groups[#groups + 1] = { label = page.label, build = function(parent, y)
            local holder = CreateFrame("Frame", nil, parent)
            holder:SetPoint("TOPLEFT", 0, y)
            holder:SetSize(CONTENT_WIDTH, 10)
            local h = build(holder) or 0
            holder:SetHeight(h)
            return y - h
        end }
    end
    Options.AddSection(key, { groups = groups })
end

---------------------------------------------------------------------------
-- Pages: where "Open page" and Go lead. Through the page list when it can;
-- otherwise the window that holds that content.
---------------------------------------------------------------------------
local function ShowWindow(module, view)
    local m = ns[module]
    if m and m.Show then m.Show(view) return true end
    return false
end

local FALLBACK = {
    enemies = function(tab)
        if ns.EnemiesUI and ns.EnemiesUI.ShowPage then ns.EnemiesUI.ShowPage(tab) return true end
        Options.OpenSection("enemies")
        return true
    end,
    fishing = function(tab) return ShowWindow("FishingUI", tab or "now") end,
    groups = function() return ShowWindow("GroupsUI") end,
    gear = function(tab)
        local views = { gear = "snapshots", enhance = "enhance", ledger = "ledger", progress = "progress" }
        return ShowWindow("GearUI", views[tab or ""])
    end,
    prof = function(tab)
        if tab == "profit" then return ShowWindow("MarketUI", "crafting") end
        local views = { plan = "professions", skills = "skills", log = "crafting" }
        return ShowWindow("GearUI", views[tab or ""] or "professions")
    end,
    gold = function() return ShowWindow("EconomyUI") end,
    ah = function() return ShowWindow("MarketUI") or ShowWindow("AuctionDeskUI") end,
    recruit = function(tab)
        local views = { find = "recruit", invited = "invited", results = "recruiters" }
        return ShowWindow("GuildUI", views[tab or ""] or "recruit")
    end,
    members = function(tab, view)
        if view == "Activity" then return ShowWindow("GuildUI", "activity") end
        local views = { roster = "roster", promotions = "promote", log = "log", sharing = "sharing" }
        return ShowWindow("GuildUI", views[tab or ""] or "roster")
    end,
    audit = function() return ShowWindow("AuditUI") end,
}

-- route: "page", "page/tab" or "page/tab#View" (a settings route opens that section).
function Options.OpenRoute(route)
    local page, tab, view = (route or ""):match("^([^/#]+)/?([^#]*)#?(.*)$")
    if not page then return false end
    if page == "settings" then
        Options.OpenSection(tab ~= "" and tab or nil)
        return true
    end
    tab = tab ~= "" and tab or nil
    view = view ~= "" and view or nil
    if ns.Nav and ns.Nav.Go and ns.Nav.Go(page, tab, view) then return true end
    local fallback = FALLBACK[page]
    return fallback and fallback(tab, view) and true or false
end

function Options.OpenPage(page, tab) return Options.OpenRoute(page .. (tab and ("/" .. tab) or "")) end

---------------------------------------------------------------------------
-- Groups built here (the addon-wide ones and today's General / Alerts / Safety
-- / Stealth / Journal / Advanced tabs, moved into their sections)
---------------------------------------------------------------------------
local function ApplyLook()
    if ns.Style.ApplySettings then ns.Style.ApplySettings() end
end
local LOOK_NOTE = " Open windows change after a /reload."

Options.AddSection("general", {
    status = function() return "v" .. tostring(ns.VERSION) .. "  ·  " .. tostring(ns.FLAVOR_NAME) end,
    groups = {
        { label = ns.NAME, build = function(p, y)
            return (Checkbox(p, y, "enabled", "Enable " .. ns.NAME, "Turns the panel, alerts, badges and safety warnings on or off."))
        end },
        { label = "Colors", build = function(p, y)
            y = Checkbox(p, y, "colorblind", "Colorblind-friendly colors", "Blue / orange / magenta instead of green / yellow / red.")
            y = Checkbox(p, y, "classicLook", "Classic look", "The look of earlier versions: rounded colours, the old fonts and title bars."
                .. LOOK_NOTE, nil, nil, { onChange = ApplyLook })
            y = Cycle(p, y, "textSize", "Text size", { { value = 11, label = "Small (11)" }, { value = 12, label = "Normal (12)" },
                { value = 13, label = "Large (13)" } }, "Body text in lists and pages." .. LOOK_NOTE, { onChange = ApplyLook })
            y = Checkbox(p, y, "compactRows", "Compact rows", "List rows 18 high instead of 20, so more fit." .. LOOK_NOTE,
                nil, nil, { onChange = ApplyLook })
            return y
        end },
        { label = "Minimap button", build = function(p, y)
            return (Checkbox(p, y, "minimapButton", "Minimap button", "Left-click: where you left off. Shift: Gold. Alt: Auction House. "
                .. "Ctrl: Enemies nearby panel. Right-click: Settings. Shift+right: Guild. Drag to move it. Also " .. ns.Cmd.Text("minimap") .. "."))
        end },
        { label = "Updates", build = function(p, y)
            return (Checkbox(p, y, "versionCheck", "Tell me when a newer " .. ns.NAME .. " exists", "Joins a hidden channel where "
                .. ns.NAME .. " copies pass on signed release notes (addon messages, never chat; players of your faction can see you in "
                .. "the channel's member list). A newer version opens a window with how to update, then at every login until you do, "
                .. "never in combat. Also " .. ns.Cmd.Text("version") .. "."))
        end },
    },
})

local function DistanceText()
    local d = ns.GetCVarNumber(C.NAMEPLATE_DISTANCE_CVAR)
    return "Current nameplate distance: " .. (d and (ns.FormatNumber(d) .. " yd") or (ns.ColorCode("unknown") .. "unknown|r"))
end

Options.AddSection("enemies", {
    status = function()
        local rowsN, players = ns.Journal.Stats()
        local text = string.format("%d sightings of %d players", rowsN, players)
        if ns.Census and ns.Census.Stats then text = text .. string.format("  ·  %d census points", (ns.Census.Stats())) end
        return text
    end,
    groups = {
        { label = "Panel", build = function(p, y)
            y = Paragraph(p, y, "Enemy players near you, from their nameplates (up to ~41 yd), your target and your mouseover. "
                .. "Live enemies are sorted by threat (level, your lists, closeness); recently seen ones fade out below them. "
                .. "Distances are brackets from the game's range checks: |cffffffff8–10 yd|r. "
                .. ns.ColorCode("unknown") .. "? yd|r means the game gave no answer (usually in combat).", "GameFontHighlightSmall")
            y = Checkbox(p, y, "panelShown", "Show the panel")
            y = Checkbox(p, y, "panelLocked", "Lock position", "Locked, Shift + drag still moves it.", 40)
            y = Checkbox(p, y, "panelHideEmpty", "Hide while empty (when locked)", nil, 40)
            y = Checkbox(p, y, "panelClickTarget", "Click a row to target", "Out of combat only: the game does not let addons change click targets in combat.", 40)
            y = Slider(p, y, "panelScale", "Size", 0.6, 2.0, 0.1, "%.1fx")
            y = Paragraph(p, y, "A second line under each enemy in view: health in hit points, power, "
                .. "tags (" .. ns.ColorCode("danger") .. "@you|r targeting you, " .. ns.ColorCode("danger") .. "PvP|r flagged, "
                .. ns.ColorCode("threshold") .. "cast|r casting, cbt in combat) and their buffs and debuffs. Big cooldowns have a "
                .. ns.ColorCode("danger") .. "red|r border, crowd control a " .. ns.ColorCode("threshold") .. "yellow|r one. "
                .. "A " .. ns.ColorCode("unknown") .. "?|r means the game hides it. Hover a row for everything in words.", "GameFontDisableSmall")
            y = Checkbox(p, y, "panelDetails", "Show health, tags, buffs and debuffs")
            y = Button(p, y, "Reset position", 140, function() ns.Panel.ResetPosition() end)
            y = Fine(p, y)
            y = Slider(p, y, "panelRows", "Rows", 3, 20, 1, "%d")
            y = Slider(p, y, "panelFadeSeconds", "Keep listed after they leave view", 10, 300, 10, "%ds")
            y = Slider(p, y, "panelMaxAuras", "Buff / debuff icons per enemy", 0, 10, 1, "%d")
            return y
        end },
        { label = "Nameplates", build = function(p, y)
            y = Paragraph(p, y, "A small label left of each enemy player's nameplate: level difference to you "
                .. "(" .. ns.ColorCode("danger") .. "??|r = 10+ above), and KoS / avoid when they are on a list.", "GameFontDisableSmall")
            y = Checkbox(p, y, "badgesEnabled", "Show badges on enemy nameplates")
            y = Paragraph(p, y, "Above your enemy target's nameplate: distance bracket and the key spells "
                .. "of your class that reach right now (" .. ns.ColorCode("safe") .. "green|r). The panel footer lists all of them.",
                "GameFontDisableSmall")
            y = Checkbox(p, y, "targetReadout", "Show the target readout")
            y = Paragraph(p, y, "Enemies are noticed when their nameplate appears. The game's maximum nameplate distance "
                .. "gives you the earliest warning.", "GameFontHighlightSmall")
            local rowY = y
            Button(p, rowY, "Max nameplate distance", 200, function()
                if ns.Main and ns.Main.SetMaxNameplateDistance then ns.Main.SetMaxNameplateDistance() end
            end, "Also " .. ns.Cmd.Text("distance") .. " max.")
            local _, fs = LiveText(p, rowY - 5, 20, DistanceText)
            fs:ClearAllPoints()
            fs:SetPoint("TOPLEFT", 236, rowY - 5)
            fs:SetWidth(CONTENT_WIDTH - 260)
            y = y - 30
            y = Fine(p, y)
            y = Checkbox(p, y, "targetSpells", "Include your spell ranges", nil, 40)
            return y
        end },
        { label = "Journal", build = function(p, y)
            y = Checkbox(p, y, "journalEnabled", "Record enemy players I see",
                "Name, class, level, guild, zone and time. Repeat sightings of a player in the same zone are merged.")
            y = Fine(p, y)
            y = Slider(p, y, "journalMax", "Keep at most", 500, 20000, 500, "%d sightings")
            y = Slider(p, y, "journalMergeMinutes", "One visit if seen again within", 1, 60, 1, "%d min",
                "Sightings of the same player in the same zone within this time are one row of the journal.")
            return y
        end },
    },
})

Options.AddSection("alerts", {
    status = function()
        local d = db()
        return "Alerts " .. (d.alertsEnabled and "on" or "muted") .. "  ·  PvP flag " .. (d.flagIndicator and "shown" or "hidden")
    end,
    groups = {
        { label = "When to alert", build = function(p, y)
            y = Paragraph(p, y, "An alert fires the first time an enemy player shows up, then not again for that player until "
                .. "the repeat time has passed. Players the game hides hostility for never alert; the panel shows them with "
                .. ns.ColorCode("unknown") .. "?|r.", "GameFontHighlightSmall")
            y = Checkbox(p, y, "alertsEnabled", "Enable alerts", "Notifications when an enemy appears. "
                .. "Off: the panel still lists every enemy, silently. Also the button in the panel's title bar and "
                .. ns.Cmd.Text("alerts") .. " on|off.")
            y = Checkbox(p, y, "alertOnNameplate", "When an enemy nameplate appears", nil, 40)
            y = Checkbox(p, y, "alertOnTarget", "When you target an enemy", nil, 40)
            y = Checkbox(p, y, "alertOnMouseover", "When you mouse over an enemy", nil, 40)
            y = Paragraph(p, y, "Loud alerts: bigger text and the alert sound.", "GameFontDisableSmall")
            y = Checkbox(p, y, "alertLoudKoS", "Players on your kill-on-sight list")
            y = Slider(p, y, "alertLoudAbove", "Enemies this many levels above you", 1, 10, 1, function(v) return "+" .. v .. " and ??" end)
            y = Paragraph(p, y, "Always loud for these classes:", "GameFontHighlightSmall")
            for i, classFile in ipairs(C.CLASSES) do
                local column = (i - 1) % 3
                local label = ns.Hex(ns.ClassColor(classFile)) .. ns.ClassName(classFile) .. "|r"
                Checkbox(p, y, classFile, label, nil, 30 + column * 180, "alertLoudClasses")
                if column == 2 or i == #C.CLASSES then y = y - 28 end
            end
            y = Fine(p, y)
            y = Slider(p, y, "alertMinLevelGap", "Only enemies from (levels vs you)", -60, 10, 1, function(v)
                return v <= -60 and "any level" or Signed(v)
            end, "Ignore enemies far below you. Skulls and your KoS list always alert.")
            y = Slider(p, y, "alertRepeatSeconds", "Repeat for the same player after", 30, 900, 30, function(v)
                return v >= 60 and (math.floor(v / 60) .. " min" .. (v % 60 > 0 and (" " .. v % 60 .. "s") or "")) or (v .. "s")
            end)
            return y
        end },
        { label = "How to alert", build = function(p, y)
            y = Checkbox(p, y, "alertCenterText", "Center-screen text")
            y = Checkbox(p, y, "alertChat", "Chat line (with zone)")
            y = Checkbox(p, y, "alertSound", "Sound for loud alerts")
            local soundChoices = {}
            for _, sound in ipairs(ns.ALERT_SOUNDS) do soundChoices[#soundChoices + 1] = { value = sound.key, label = sound.label } end
            y = Cycle(p, y, "alertSoundChoice", "Sound", soundChoices)
            y = Button(p, y, "Test alert", 160, function() ns.Alerts.Reset(); ns.Alerts.Test() end, "Shows a loud alert with the current settings.")
            return y
        end },
        { label = "Stealth", build = function(p, y)
            y = Paragraph(p, y, "Rogues and druids leave no trace once stealthed: the game removes their nameplate. "
                .. "When an enemy rogue or druid's nameplate disappears close to you while they were alive, they most likely "
                .. "stealthed (Stealth, Prowl, Vanish). Logging out or a mount flying off look the same, so this is a heuristic and off by default.",
                "GameFontHighlightSmall")
            y = Checkbox(p, y, "vanishAlert", "Alert when a stealther vanishes nearby")
            y = Fine(p, y)
            y = Slider(p, y, "vanishMaxRange", "Only when they were within", 10, 40, 5, "%d yd")
            return y
        end },
        { label = "PvP flag and zones", build = function(p, y)
            y = Paragraph(p, y, "For Hardcore characters, where one PvP flag can end a run. " .. ns.NAME .. " cannot stop an action; "
                .. "it warns when you target a player that acting on would flag you.", "GameFontHighlightSmall")
            y = Checkbox(p, y, "flagIndicator", "Always show my PvP flag", "PvP off / PvP ON / PvP ON · off in 4:12. "
                .. ns.ColorCode("unknown") .. "?|r when the game hides it.")
            y = Checkbox(p, y, "flagWarnTarget", "Warn when my target would flag me",
                "While you are unflagged: targeting an enemy player, their pet or an enemy-faction NPC such as a guard (attacking flags you), "
                .. "or a flagged friendly player (healing or buffing flags you).")
            y = Checkbox(p, y, "zoneBanner", "Banner when entering contested or enemy territory",
                "With the number of enemies " .. ns.NAME .. " saw there in the last 24 hours.")
            y = Button(p, y, "Reset position", 140, function() ns.Safety.ResetPosition() end, "Puts the PvP flag back in its place.")
            y = Fine(p, y)
            y = Checkbox(p, y, "flagLocked", "Lock its position", "Locked, Shift + drag still moves it.", 40)
            return y
        end },
    },
})

---------------------------------------------------------------------------
-- Data > Delete data: every bulk delete, one row per store, each asking first.
---------------------------------------------------------------------------
StaticPopupDialogs[ns.POPUP .. "DELETE"] = {
    text = "Delete " .. ns.NAME .. " sightings %s?",
    button1 = YES or "Yes",
    button2 = NO or "No",
    OnAccept = function(self, days)
        local removed = ns.Journal.Delete(days or nil)
        ns.Print(removed .. " sightings deleted.")
        Apply()
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

StaticPopupDialogs[ns.POPUP .. "SET_ASIDE_DELETE"] = {
    text = "Delete %s " .. ns.NAME .. " set-aside entries (saved entries that could not be read)? This cannot be undone.",
    button1 = YES or "Yes",
    button2 = NO or "No",
    OnAccept = function()
        local q = ns.Store.Quarantined()
        if type(q) == "table" then for i = #q, 1, -1 do q[i] = nil end end
        ns.Print("set-aside entries deleted.")
        Apply()
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

local function Ask(popup, text, data) return function() StaticPopup_Show(ns.POPUP .. popup, text, nil, data) end end
local function CharKey() return ns.Gear and ns.Gear.CharKey() or nil end

-- { label, size = fn() -> text, buttons = { { text, onClick, tooltip, width } } }
local function DeleteStores()
    local list = {}
    local keep = "Lists and notes are kept; a player with neither and no sightings left is forgotten."
    list[#list + 1] = { label = "Sightings", size = function()
        local n, players = ns.Journal.Stats()
        return string.format("%d sightings of %d players", n, players)
    end, buttons = {
        { "30+ days", Ask("DELETE", "older than 30 days", 30), "Sightings older than 30 days. " .. keep },
        { "7+ days", Ask("DELETE", "older than 7 days", 7), "Sightings older than 7 days. " .. keep },
        { "All", Ask("DELETE", "(all of them)", false), "Every sighting. " .. keep },
    } }
    if ns.Census then
        list[#list + 1] = { label = "Census", size = function()
            local points, cells, maps = ns.Census.Stats()
            return string.format("%d recent points, %d summary cells on %d maps", points, cells, maps)
        end, buttons = {
            { "Recent", Ask("CENSUS_DELETE", "recent census points (the summary is kept)", "points"), "Recent points only; the summary is kept." },
            { "All", Ask("CENSUS_DELETE", "all census data", "all"), "Points and the summary." },
        } }
    end
    if ns.Gear then
        list[#list + 1] = { label = "Gear", size = function()
            local snaps, ledger = ns.Gear.Stats()
            return string.format("this character: %d snapshots, %d ledger entries", snaps, ledger)
        end, buttons = {
            { "This character", function() StaticPopup_Show(ns.POPUP .. "GEAR_DELETE", CharKey() or "?", nil, CharKey()) end,
                "All gear data of this character.", 110 },
        } }
    end
    if ns.Skills then
        list[#list + 1] = { label = "Skills", size = function()
            local c = ns.Skills.Char()
            return string.format("this character: %d log entries", c and c.log and #c.log or 0)
        end, buttons = {
            { "This character", function() StaticPopup_Show(ns.POPUP .. "SKILLS_DELETE", CharKey() or "?", nil, CharKey()) end,
                "The skill log of this character.", 110 },
        } }
    end
    if ns.Economy then
        list[#list + 1] = { label = "Economy", size = function()
            local c = ns.Economy.Char()
            return string.format("this character: %d transactions", c and c.log and #c.log or 0)
        end, buttons = {
            { "This character", function() StaticPopup_Show(ns.POPUP .. "ECONOMY_DELETE", CharKey() or "?", nil, CharKey()) end,
                "The economy log of this character.", 110 },
        } }
    end
    if ns.Fishing then
        list[#list + 1] = { label = "Fishing casts", size = function()
            local casts = ns.Fishing.Counts and ns.Fishing.Counts() or 0
            return string.format("%d recent casts", casts)
        end, buttons = {
            { "Delete", Ask("FISHING_DELETE", "recent fishing casts (spots, heat map and sessions are kept)", "casts"),
                "The cast log; spots, heat map squares and sessions are kept." },
        } }
        list[#list + 1] = { label = "All fishing data", size = function()
            local _, spots, sessions = 0, 0, 0
            if ns.Fishing.Counts then _, spots, sessions = ns.Fishing.Counts() end
            return string.format("%d spots, %d sessions", spots or 0, sessions or 0)
        end, buttons = {
            { "Delete", Ask("FISHING_DELETE", "fishing data (all spots, heat maps, sessions and logs)", "all"),
                "Spots, heat maps, sessions and logs." },
        } }
    end
    list[#list + 1] = { label = "Set-aside entries", size = function()
        local q = ns.Store.Quarantined()
        return string.format("%d entries", type(q) == "table" and #q or 0)
    end, buttons = {
        { "Delete", function()
            local q = ns.Store.Quarantined()
            local n = type(q) == "table" and #q or 0
            if n == 0 then ns.Print("no set-aside entries.") return end
            StaticPopup_Show(ns.POPUP .. "SET_ASIDE_DELETE", tostring(n))
        end, "Saved entries that could not be read at login and were put aside. Also " .. ns.Cmd.Text("data") .. " clear." },
    } }
    return list
end

local deleteButtons = {}
-- The Delete buttons by store and button text (for tests and Go).
function Options.DeleteButton(store, text) return deleteButtons[store] and deleteButtons[store][text] end

local function BuildDeleteData(p, y)
    y = Paragraph(p, y, "Each button asks first. Deleting one record (a snapshot, a group, an Audit character) is on its page.",
        "GameFontHighlightSmall")
    for _, store in ipairs(DeleteStores()) do
        local fs = Style.Text(p, "GameFontHighlight")
        fs:SetPoint("TOPLEFT", 22, y - 4)
        fs:SetText(store.label)
        local size = Style.Text(p, "GameFontHighlightSmall")
        size:SetPoint("TOPLEFT", 160, y - 5)
        size:SetWidth(240)
        size.Refresh = function(self) self:SetText(store.size()) end
        Track(size)
        local x = CONTENT_WIDTH - 12
        for i = #store.buttons, 1, -1 do
            local def = store.buttons[i]
            local w = def[4] or 64
            x = x - w
            local b = Style.Button(p, def[1], w, def[2], def[3], { kind = "danger", small = true })
            b:SetPoint("TOPLEFT", x, y - 2)
            deleteButtons[store.label] = deleteButtons[store.label] or {}
            deleteButtons[store.label][def[1]] = b
            x = x - 4
        end
        y = y - 26
    end
    return y - 4
end

Options.AddSection("data", { groups = { { label = "Delete data", build = BuildDeleteData } } })

---------------------------------------------------------------------------
-- Advanced: reports, the whisper pace, the version check, reset.
---------------------------------------------------------------------------
local function ErrorCount()
    local log = db().errorLog
    return type(log) == "table" and #log or 0
end

local function PaceText()
    local O = ns.Outbox
    if not (O and O.Burst) then return "" end
    local hold = O.Hold and O.Hold() or 0
    local waiting = O.Pending and O.Pending() or 0
    return string.format("At most %d whispers queued (%s)%s%s.", O.Burst(),
        O.Learned and O.Learned() and "learned from the game's limit" or "default",
        hold > 0 and string.format(", paused %d s more", math.ceil(hold)) or "",
        waiting > 0 and string.format(", %d waiting to go out", waiting) or "")
end

local function VersionText()
    local V = ns.Version
    if not (V and V.StatusLines) then return "" end
    local lines = V.StatusLines()
    return (lines[1] or "") .. "\n" .. ((lines[3] or ""):gsub("^%s+", ""))
end

local function ActionRow(p, y, label, compute, buttons)
    local fs = Style.Text(p, "GameFontHighlight")
    fs:SetPoint("TOPLEFT", 22, y - 4)
    fs:SetText(label)
    local text
    if compute then
        text = Style.Text(p, "GameFontHighlightSmall")
        text:SetPoint("TOPLEFT", 160, y - 5)
        text:SetWidth(270)
        text.Refresh = function(self) self:SetText(compute()) end
        Track(text)
    end
    local x, made = CONTENT_WIDTH - 12, {}
    for i = #buttons, 1, -1 do
        local def = buttons[i]
        local w = def[4] or 70
        x = x - w
        local b = Style.Button(p, def[1], w, def[2], def[3], { small = true, kind = def[5] })
        b:SetPoint("TOPLEFT", x, y - 2)
        made[i] = b
        x = x - 4
    end
    return y - 26, made
end

Options.AddSection("advanced", {
    status = function() return ErrorCount() .. " errors this version  ·  v" .. tostring(ns.VERSION) end,
    groups = {
        { label = "Reports", build = function(p, y)
            y = Paragraph(p, y, "The probe reports what this client lets addons read about enemy players (names, levels, "
                .. "flags, distance, auras, casts, addon messages, battleground data), in or out of combat. Run it near an enemy "
                .. "player, once out of combat and once in combat, and keep the result for the developer.", "GameFontHighlightSmall")
            y = ActionRow(p, y, "API probe", nil, {
                { "Run", function() if ns.Probe then ns.Probe.Run() end end, "Target an enemy player first if you can." } })
            y = ActionRow(p, y, "Error log", function() return ErrorCount() .. " errors" end, {
                { "Show", function() ns.ShowErrors() end, ns.NAME .. "'s own errors, in a window you can copy from." },
                { "Clear", function()
                    db().errorLog = {}
                    ns.Print("error log cleared.")
                    Apply()
                end, "Empties the error log. Also " .. ns.Cmd.Text("errors") .. " clear." } })
            y = ActionRow(p, y, "Timings", nil, {
                { "Show", function() if ns.Main then ns.Main.ShowTimings() end end,
                    "The slowest work this session, to paste into a report about frame lag. Also " .. ns.Cmd.Text("perf") .. "." },
                { "Clear", function() if ns.Main then ns.Main.ShowTimings("reset") end end,
                    "Starts the timings over. Also " .. ns.Cmd.Text("perf", "reset") .. "." } })
            y = Paragraph(p, y, "What " .. ns.NAME .. " keeps, for the whole account and for each character, whether what you "
                .. "share with officers is unchanged since your last logout (the tamper seal), and entries set aside because they could "
                .. "not be read.", "GameFontHighlightSmall")
            y = ActionRow(p, y, "Saved data", nil, {
                { "Show", function()
                    if ns.Probe and ns.Probe.ShowText then ns.Probe.ShowText(ns.Store.ReportText()) end
                end, "Entries per store, by character. " .. ns.Cmd.Text("data") .. " does the same." } })
            return y
        end },
        { label = "Whisper pace", build = function(p, y)
            local _, made = ActionRow(p, y, "Whispers", PaceText, {
                { "Forget learned limit", function()
                    if ns.Outbox and ns.Outbox.ResetBurst then ns.Outbox.ResetBurst() end
                    ns.Print("learned whisper limit forgotten.")
                    Apply()
                end, "Back to the default queue limit. Also " .. ns.Cmd.Text("pace") .. " reset.", 130 } })
            local forget = made[1]
            Track({ Refresh = function()
                local learned = ns.Outbox and ns.Outbox.Learned and ns.Outbox.Learned()
                if forget.SetEnabled then forget:SetEnabled(learned and true or false, "nothing learned yet") end
            end })
            return y - 30
        end },
        { label = "Version check", build = function(p, y)
            y = ActionRow(p, y, "Status", VersionText, {
                { "Show", function()
                    if ns.Probe and ns.Probe.ShowText and ns.Version then ns.Probe.ShowText(table.concat(ns.Version.StatusLines(), "\n")) end
                end, "What the version check sees, in words. Also " .. ns.Cmd.Text("version") .. " status." } })
            return y - 8
        end },
        { label = "Reset", build = function(p, y)
            local made
            y, made = ActionRow(p, y, "All settings", function() return "back to default; asks first" end, {
                { "Reset all settings", function()
                    if ns.Main and ns.Main.AskReset then ns.Main.AskReset() else StaticPopup_Show(ns.POPUP .. "RESET") end
                end, "Settings and positions. Your journal, lists, census, gear ledger, skills, economy log, prices and fishing log are kept.",
                    140, "danger" } })
            Options.resetButton = made[1]
            return y
        end },
    },
})

StaticPopupDialogs[ns.POPUP .. "RESET"] = {
    text = "Reset all " .. ns.NAME .. " settings and window positions? Your logged data (journal, lists, census, gear, skills, economy, prices, fishing) is kept.",
    button1 = YES or "Yes",
    button2 = NO or "No",
    OnAccept = function()
        if InCombatLockdown and InCombatLockdown() then
            ns.Print("settings cannot be reset in combat; try again after the fight.")
            return
        end
        if ns.Main then ns.Main.ResetSettings() end
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

---------------------------------------------------------------------------
-- Window: the section list on the left, search and filters on top, then
-- either the page or the list of matching settings.
---------------------------------------------------------------------------
-- A plain scroll frame with mouse-wheel scrolling and a thin position bar
-- (no template: same look everywhere). scroll.offset is where it stands.
local function MakeScroll(parent)
    local scroll = CreateFrame("ScrollFrame", nil, parent)
    scroll:SetPoint("TOPLEFT", 4, -4)
    scroll:SetPoint("BOTTOMRIGHT", -10, 4)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(CONTENT_WIDTH, 100)
    scroll:SetScrollChild(child)
    scroll.child = child
    scroll.offset = 0
    local track = Style.Texture(parent, "ARTWORK", COLORS.trackDim)
    track:SetWidth(3)
    track:SetPoint("TOPRIGHT", -4, -6)
    track:SetPoint("BOTTOMRIGHT", -4, 6)
    local thumb = Style.Texture(parent, "OVERLAY", { COLORS.accent[1], COLORS.accent[2], COLORS.accent[3], 0.6 })
    thumb:SetWidth(3)
    local function UpdateBar()
        local view, total = scroll:GetHeight() or 0, child:GetHeight() or 0
        local shown = total > view + 1 and view > 0
        track:SetShown(shown)
        thumb:SetShown(shown)
        if not shown then return end
        local range = total - view
        local h = math.max(20, (view - 12) * view / total)
        local offset = math.min(1, scroll.offset / range) * (view - 12 - h)
        thumb:ClearAllPoints()
        thumb:SetHeight(h)
        thumb:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -4, -6 - offset)
    end
    function scroll:MaxScroll() return math.max(0, (child:GetHeight() or 0) - (self:GetHeight() or 0)) end
    function scroll:ScrollTo(value)
        value = math.max(0, math.min(self:MaxScroll(), value or 0))
        self.offset = value
        self:SetVerticalScroll(value)
        UpdateBar()
        if self.onScroll then self.onScroll(value) end
    end
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta) self:ScrollTo(self.offset - delta * 40) end)
    scroll:SetScript("OnShow", UpdateBar)
    scroll:SetScript("OnSizeChanged", UpdateBar)
    scroll.UpdateBar = UpdateBar
    return scroll
end

local nav = {}
local area, pageScroll, resultsHolder, resultsScroll, searchBox, chips, countText, emptyText
local sectionTop, sectionOrder, current = {}, {}, nil
local query, filter = "", "all"
local resultRows = {}
local flash, flashFrame, lastFlash

local function PaintNav()
    for _, b in ipairs(nav) do
        local selected = b.key == current
        b.accent:SetShown(selected)
        Style.Fill(b.bg, selected and COLORS.selected or COLORS.clear)
        local c = selected and COLORS.t1 or COLORS.t3
        b.text:SetTextColor(c[1], c[2], c[3])
    end
end

local function SetCurrent(key)
    if key == current then return end
    current = key
    PaintNav()
end

-- The section the page stands in: the last one whose top is above the view.
local function OnScroll(offset)
    local key = sectionOrder[1]
    for _, k in ipairs(sectionOrder) do
        if (sectionTop[k] or 0) <= offset + 8 then key = k end
    end
    SetCurrent(key)
end

local function StatusFor(key)
    local d = sectionDefs[key]
    if not (d and d.status) then return "" end
    local text = ""
    ns.SafeCall(function() text = d.status() or "" end)
    return text
end

local function SectionHeader(child, y, sec)
    y = y - 6
    local band = Style.Texture(child, "BACKGROUND", COLORS.band or COLORS.card)
    band:SetPoint("TOPLEFT", 4, y + 4)
    band:SetSize(CONTENT_WIDTH - 8, 48)
    local title = Style.Text(child, "title")
    title:SetPoint("TOPLEFT", 12, y - 4)
    title:SetText(sec.label)
    local status = Style.Text(child, "meta")
    status:SetPoint("TOPLEFT", 12, y - 24)
    status:SetWidth(CONTENT_WIDTH - 190)
    status.Refresh = function(self) self:SetText(StatusFor(sec.key)) end
    controls[#controls + 1] = status
    sec.statusText = status
    local x = CONTENT_WIDTH - 12
    if sec.page then
        local open = Style.Button(child, "Open page", 90, function() Options.OpenPage(sec.page) end,
            "Opens the page these settings belong to.", { small = true, glyph = "chevronright" })
        x = x - 90
        open:SetPoint("TOPLEFT", x, y - 4)
        sec.openButton = open
    end
    if sec.key == "enemies" then
        -- The journal, the lists and the census moved to the Enemies page.
        for i = 3, 1, -1 do
            local tab = ({ "journal", "lists", "census" })[i]
            local b = Style.Button(child, ({ "Journal", "Lists", "Census" })[i], 62, function() Options.OpenPage("enemies", tab) end,
                "Opens the Enemies page on this tab.", { small = true })
            x = x - 66
            b:SetPoint("TOPLEFT", x, y - 4)
        end
    end
    return y - 54
end

local function BuildContent(child)
    local y = -4
    for _, sec in ipairs(Options.SECTIONS) do
        building = sec.key
        sectionTop[sec.key] = -y
        sectionOrder[#sectionOrder + 1] = sec.key
        y = SectionHeader(child, y, sec)
        for _, group in ipairs(OrderedGroups(sec)) do
            y = Header(child, y, group.label)
            for _, build in ipairs(group.builds) do
                local nextY
                ns.SafeCall(function() nextY = build(child, y) end)
                if type(nextY) == "number" then y = nextY end
            end
            y = y - 8
        end
        y = y - 10
    end
    building = nil
    return -y + 20
end

---------------------------------------------------------------------------
-- Search and filters: a list of matching settings, each with Go.
---------------------------------------------------------------------------
local FILTERS = { { key = "all", label = "All" }, { key = "notify", label = "Alerts and chat" }, { key = "changed", label = "Changed" } }

local function HomeLabel(row)
    local sec = row.home:match("^settings/([%w]+)")
    if sec and sectionOf[sec] then return "Settings > " .. sectionOf[sec].label end
    return PLACES[row.home] or row.home
end

local function Haystack(row)
    return (row.label .. " " .. row.key .. " " .. (help[row.key] or "") .. " " .. HomeLabel(row)):lower()
end

-- The rows that match the words (all of them) and the filter, one per key.
function Options.Results(text, which)
    which = which or "all"
    local words = {}
    for w in (text or ""):lower():gmatch("%S+") do words[#words + 1] = w end
    local out, seen = {}, {}
    for _, row in ipairs(Options.SETTINGS) do
        local ok = row.type ~= "internal" and not seen[row.key]
        if ok and which == "notify" then ok = row.notify == true end
        if ok and which == "changed" then ok = row.home:find("^settings/") ~= nil and Options.IsChanged(row.key) end
        if ok and #words > 0 then
            local hay = Haystack(row)
            for _, w in ipairs(words) do
                if not hay:find(w, 1, true) then ok = false break end
            end
        end
        if ok then
            seen[row.key] = true
            out[#out + 1] = row
        end
    end
    return out
end

local function CountKeys(which)
    return #Options.Results("", which)
end

function Options.GoTo(key)
    local row = rows[key]
    if row and row.section and pageScroll then
        Options.Open()
        Options.SetSearch("")
        Options.SetFilter("all")
        pageScroll:ScrollTo(math.max(0, -row.y - 60))
        Options.Flash(key)
        return true
    end
    local s = byKey[key]
    if s and not s.home:find("^settings/") then return Options.OpenRoute(s.home) end
    return false
end

function Options.Flash(key)
    local row = rows[key]
    if not row then return end
    if not flash then
        flash = Style.Texture(pageScroll.child, "BACKGROUND", { COLORS.accent[1], COLORS.accent[2], COLORS.accent[3], 0.22 })
        flashFrame = CreateFrame("Frame")
    end
    flash:ClearAllPoints()
    flash:SetPoint("TOPLEFT", row.parent, "TOPLEFT", 4, row.y + 2)
    flash:SetSize(CONTENT_WIDTH - 8, 28)
    flash:SetAlpha(1)
    flash:Show()
    lastFlash = key
    flashFrame.left = 1.6
    flashFrame:SetScript("OnUpdate", function(self, elapsed)
        self.left = self.left - (elapsed or 0)
        if self.left <= 0 then
            flash:Hide()
            self:SetScript("OnUpdate", nil)
        else
            flash:SetAlpha(math.min(1, self.left))
        end
    end)
end

local function ResultRow(i)
    local r = resultRows[i]
    if r then return r end
    r = CreateFrame("Frame", nil, resultsScroll.child)
    r:SetSize(CONTENT_WIDTH - 8, 36)
    r:SetPoint("TOPLEFT", 4, -(i - 1) * 36)
    r.label = Style.Text(r, "body")
    r.label:SetPoint("TOPLEFT", 10, -4)
    r.label:SetWidth(CONTENT_WIDTH - 150)
    r.path = Style.Text(r, "meta")
    r.path:SetPoint("TOPLEFT", 10, -20)
    r.path:SetWidth(CONTENT_WIDTH - 150)
    r.go = Style.Button(r, "Go", 50, function() Options.GoTo(r.key) end, "Shows this setting where it lives.", { small = true })
    r.go:SetPoint("RIGHT", -8, 0)
    r.reset = Style.IconButton(r, "reset", function() Options.ResetKey(r.key) end, { "Back to default" }, { small = true })
    r.reset:SetPoint("RIGHT", r.go, "LEFT", -6, 0)
    local line = Style.HLine(r)
    line:SetPoint("BOTTOMLEFT", 4, 0)
    line:SetPoint("BOTTOMRIGHT", -4, 0)
    resultRows[i] = r
    return r
end

local function ShowResults(list)
    for i, row in ipairs(list) do
        local r = ResultRow(i)
        r.key = row.key
        r.label:SetText(row.label)
        local path = HomeLabel(row)
        if not row.home:find("^settings/") then
            path = path .. "  ·  on that page"
        elseif filter == "changed" then
            path = path .. "  ·  now " .. ValueText(Value(row.key)) .. ", default " .. ValueText(Default(row.key))
        end
        r.path:SetText(path)
        r.reset:SetShown(filter == "changed")
        r:Show()
    end
    for i = #list + 1, #resultRows do resultRows[i]:Hide() end
    resultsScroll.child:SetHeight(math.max(40, #list * 36 + 8))
    emptyText:SetShown(#list == 0)
    resultsScroll:ScrollTo(resultsScroll.offset)
end

local function CountLine(n)
    if filter == "notify" then
        return n .. " settings show text, play a sound or print a chat line"
    elseif filter == "changed" then
        return n .. " differ from the default"
    end
    return n .. " settings match"
end

local function UpdateView()
    if not built then return end
    local listing = query ~= "" or filter ~= "all"
    resultsHolder:SetShown(listing)
    pageScroll:GetParent():SetShown(not listing)
    chips:SetCount("all", CountKeys("all"))
    chips:SetCount("notify", CountKeys("notify"))
    chips:SetCount("changed", CountKeys("changed"))
    if listing then
        local list = Options.Results(query, filter)
        ShowResults(list)
        countText:SetText(CountLine(#list))
    else
        countText:SetText(#Options.SECTIONS .. " sections on one page")
    end
end

function Options.SetSearch(text)
    query = text or ""
    if searchBox and (searchBox:GetText() or "") ~= query then
        searchBox:SetText(query)
        if searchBox.hint then searchBox.hint:SetShown(query == "") end
        if searchBox.clear then searchBox.clear:SetShown(query ~= "") end
    end
    UpdateView()
end

function Options.SetFilter(key)
    filter = (key == "notify" or key == "changed") and key or "all"
    if chips then chips:Select(filter) end
    UpdateView()
end

function Options.Filter() return filter end
function Options.Search() return query end
function Options.ResultsShown() return resultsHolder ~= nil and resultsHolder:IsShown() end
function Options.ResultRows()
    local out = {}
    for _, r in ipairs(resultRows) do if r:IsShown() then out[#out + 1] = r end end
    return out
end
function Options.Row(key) return rows[key] end
function Options.ScrollOffset() return pageScroll and pageScroll.offset or 0 end
function Options.CurrentSection() return current end
function Options.LastFlash() return lastFlash end
function Options.SectionTop(key) return sectionTop[key] end

---------------------------------------------------------------------------
-- Building
---------------------------------------------------------------------------
local function BuildPanel()
    panel = Style.Window(ns.FRAME .. "OptionsWindow", "Settings", nil, nil, { nav = "settings" })
    panel:SetFrameStrata("DIALOG")
    panel:Hide()
    local version = Style.Text(panel, "GameFontDisableSmall", "RIGHT")
    version:SetPoint("TOPRIGHT", -40, -15)
    version:SetText("v" .. ns.VERSION .. "  ·  " .. ns.FLAVOR_NAME)
    local top = (Style.M.titleBar or 38) + 1

    -- Sections.
    local navBg = Style.Texture(panel, "BACKGROUND", COLORS.navBg)
    navBg:SetPoint("TOPLEFT", 1, -top)
    navBg:SetPoint("BOTTOMLEFT", 1, 1)
    navBg:SetWidth(NAV_WIDTH + 10)
    local navLine = Style.Texture(panel, "ARTWORK", COLORS.line)
    navLine:SetWidth(1)
    navLine:SetPoint("TOPLEFT", NAV_WIDTH + 11, -top)
    navLine:SetPoint("BOTTOMLEFT", NAV_WIDTH + 11, 1)
    for i, sec in ipairs(Options.SECTIONS) do
        local b = CreateFrame("Button", nil, panel)
        b:SetSize(NAV_WIDTH, 24)
        b:SetPoint("TOPLEFT", 6, -top - 8 - (i - 1) * 26)
        b.key = sec.key
        b.bg = Style.Texture(b, "BACKGROUND")
        b.bg:SetAllPoints()
        b.accent = Style.Texture(b, "ARTWORK", COLORS.accent)
        b.accent:SetWidth(2)
        b.accent:SetPoint("TOPLEFT")
        b.accent:SetPoint("BOTTOMLEFT")
        b.text = Style.Text(b, "body")
        b.text:SetPoint("LEFT", 12, 0)
        b.text:SetPoint("RIGHT", -28, 0)
        b.text:SetText(sec.label)
        local n = 0
        for _, row in ipairs(Options.Results("", "all")) do
            if row.home == "settings/" .. sec.key then n = n + 1 end
        end
        b.count = Style.Text(b, "meta", "RIGHT")
        b.count:SetPoint("RIGHT", -6, 0)
        b.count:SetText(n > 0 and tostring(n) or "")
        local hl = Style.Texture(b, "HIGHLIGHT", COLORS.hover)
        hl:SetAllPoints()
        b:SetScript("OnClick", function() Options.OpenSection(sec.key) end)
        nav[i] = b
    end

    -- Search and filters.
    searchBox = Style.SearchBox(panel, function(text)
        if text ~= query then
            query = text
            UpdateView()
        end
    end, "Search settings: a label, a word or a saved key")
    searchBox:SetPoint("TOPLEFT", NAV_WIDTH + 22, -top - 8)
    searchBox:SetWidth(250)
    chips = Style.Chips(panel, FILTERS, function(key) Options.SetFilter(key) end)
    chips:SetPoint("LEFT", searchBox, "RIGHT", 10, 0)
    chips:Select("all")
    countText = Style.Text(panel, "meta")
    countText:SetPoint("TOPLEFT", NAV_WIDTH + 24, -top - 34)

    area = CreateFrame("Frame", ns.FRAME .. "OptionsArea", panel)
    area:SetPoint("TOPLEFT", panel, "TOPLEFT", NAV_WIDTH + 22, -top - 50)
    area:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -12, 12)
    local areaBg = Style.Texture(area, "BACKGROUND", COLORS.card)
    areaBg:SetAllPoints()
    Style.Border(area, COLORS.cardBorder)

    local pageHolder = CreateFrame("Frame", nil, area)
    pageHolder:SetAllPoints()
    pageScroll = MakeScroll(pageHolder)
    pageScroll.onScroll = OnScroll

    resultsHolder = CreateFrame("Frame", nil, area)
    resultsHolder:SetAllPoints()
    resultsScroll = MakeScroll(resultsHolder)
    emptyText = Style.Text(resultsScroll.child, "body")
    emptyText:SetPoint("TOPLEFT", 14, -12)
    emptyText:SetText("No setting matches.")
    resultsHolder:Hide()

    panel:HookScript("OnShow", function()
        Options.Build()
        Options.Refresh()
        pageScroll.UpdateBar()
    end)
end

-- The page itself: built the first time Settings opens (or for tests).
function Options.Build()
    if built or not panel then return end
    built = true
    pageScroll.child:SetHeight(BuildContent(pageScroll.child))
    current = nil
    OnScroll(0)
    UpdateView()
end

-- The entry in the game's Options > AddOns list: it opens the window.
local function BuildLauncher()
    launcher = CreateFrame("Frame", ns.FRAME .. "OptionsPanel")
    launcher.name = ns.NAME
    launcher:Hide()
    launcher.crest = Style.BrandTexture(launcher, ns.TEX.crest, 72)
    launcher.crest:SetPoint("TOPLEFT", 16, -16)
    local title = launcher:CreateFontString(nil, "ARTWORK", "GameFontNormalHuge")
    title:SetPoint("TOPLEFT", launcher.crest, "TOPRIGHT", 14, -8)
    title:SetText(ns.TITLE)
    local text = launcher:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    text:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -10)
    text:SetWidth(520)
    text:SetJustifyH("LEFT")
    text:SetText(ns.NAME .. " has its own settings window. It opens by itself; you can also type " .. ns.Cmd.PREFIX .. ".")
    local open = Style.Button(launcher, "Open " .. ns.NAME .. " settings", 200, function() Options.Open() end)
    open:SetPoint("TOPLEFT", text, "BOTTOMLEFT", 0, -14)
    launcher:SetScript("OnShow", function() Options.Open() end)
    launcher.OnRefresh = function() end
    launcher.OnCommit = function() end
    launcher.OnDefault = function() end
    launcher.OnCancel = function() end
end

function Options.Refresh()
    -- Controls on other pages follow while their page is up.
    for _, control in ipairs(outside) do
        if control.Refresh and (not control.IsVisible or control:IsVisible()) then control:Refresh() end
    end
    -- Hidden: the page refreshes when it is shown (OnShow).
    if not panel or not panel:IsShown() or not built then return end
    for _, control in ipairs(controls) do
        if control.Refresh then control:Refresh() end
    end
    UpdateView()
end

function Options.Register()
    BuildPanel()
    BuildLauncher()
    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        local ok, cat = pcall(Settings.RegisterCanvasLayoutCategory, launcher, ns.NAME)
        if ok and cat then
            if pcall(Settings.RegisterAddOnCategory, cat) then category = cat end
        end
    end
    if not category and InterfaceOptions_AddCategory then
        pcall(InterfaceOptions_AddCategory, launcher)
    end
end

-- Plain frames: opens in combat too.
function Options.Open()
    if not panel then return end
    panel:Show()
    panel:Raise()
    Options.Build()
    Options.Refresh()
end

function Options.Toggle()
    if panel and panel:IsShown() then panel:Hide() else Options.Open() end
end

function Options.IsShown() return panel ~= nil and panel:IsShown() end

-- A section by its key, its label or the key of its page (members = Guild).
local PAGE_SECTION = { prof = "professions", recruit = "guild", members = "guild", fish = "fishing", journal = "enemies",
    lists = "enemies", census = "enemies", character = "gear", economy = "gold", market = "ah", desk = "ah", debug = "advanced" }
local function FindSection(text)
    if not text or text == "" then return nil end
    text = tostring(text):lower()
    if sectionOf[text] then return text end
    for _, sec in ipairs(Options.SECTIONS) do
        if sec.label:lower() == text then return sec.key end
    end
    return PAGE_SECTION[text]
end

function Options.ScrollToSection(key)
    if not (built and sectionTop[key]) then return end
    pageScroll:ScrollTo(sectionTop[key])
    SetCurrent(key)
end

-- Settings at a section (or, with search words, the matching settings).
-- An unknown section name searches for it.
function Options.OpenSection(key, search)
    Options.Open()
    if not built then return end
    if search and search ~= "" then
        Options.SetFilter("all")
        Options.SetSearch(search)
        return
    end
    local sec = FindSection(key)
    if not sec and key and key ~= "" then
        Options.SetFilter("all")
        Options.SetSearch(tostring(key))
        return
    end
    Options.SetSearch("")
    Options.SetFilter("all")
    if sec then Options.ScrollToSection(sec) end
end

---------------------------------------------------------------------------
-- Old entry points (tab indexes and labels) for callers not moved yet.
---------------------------------------------------------------------------
function Options.TabIndex(label) return label end

function Options.SelectTab(index)
    local sec = type(index) == "number" and Options.SECTIONS[math.max(1, math.min(#Options.SECTIONS, index))]
    if sec then Options.OpenSection(sec.key) else Options.OpenSection(index) end
end

-- The journal and the lists moved to the Enemies page.
function Options.OpenTab(tab, sub)
    if tab == "Journal" and (sub == nil or sub == 1 or sub == 2) then
        if Options.OpenPage("enemies", sub == 2 and "lists" or "journal") then return end
    end
    if type(tab) == "number" then Options.SelectTab(tab) return end
    Options.OpenSection(OLD_TABS[tab] or tab)
end
