# Changelog

## Unreleased

## 0.23.2 — 2026-10-08

### Changed

- **Much faster with a lot of saved data.** Measured on a 16 MB save with a large guild (16,000 recruits,
  11,000 guild events) and 3,500 auction items:
  - Login work is about a tenth of what it was: checking the tamper seal on what officers receive now runs over
    the first frames instead of all at once.
  - The Guild window's Recruiters, Invited, Replies and Roster tabs, the Professions plan and the Auction desk's
    Control tab no longer stall on first open: their data is prepared in the background after login, and
    reading the packed guild history is several times faster.
  - An open Auction desk or Market window no longer rebuilds every plan each minute (it produced memory churn
    the whole time it was open).
  - Lists create the parts of a row (icon, bar, columns) only when a row shows them: far fewer frames.

## 0.23.1 — 2026-10-08

### Fixed

- **Guild recruiting: the class filter has a Shaman (and Paladin) button on both factions.** WoW Forever has Alliance
  shamans and Horde paladins; they had no button, so they could not be hidden and showed even with "only this class".

## 0.23.0 — 2026-10-08

### Changed

- **Saved data from other versions is brought up to date or cleared at login.** Settings that were removed are
  dropped, renamed ones are carried over, a setting that changed form goes back to its default, and data an update
  could not convert is set aside and starts fresh instead of breaking a window. Going back to an older version keeps
  what a newer one saved, untouched, until you update again. `/talod data` lists what was changed.

## 0.22.3 — 2026-10-08

### Fixed

- **Less stutter opening the guild window.** Opening it reads the game's guild event log; with a long saved
  history (thousands of invites and joins) each read re-sorted all of it and could take 30 ms or more, several
  times per open. New entries are now slotted into place instead.

### Changed

- **`/talod perf` names more of the cleanup work:** the memory read (it walks every loaded addon) and each
  cleanup rule's count show on their own lines, so a slow moment there can be told apart.

## 0.22.2 — 2026-10-08

### Fixed

- **Guild Recruit tab:** the Next invite, Mini window and Friendly nameplates buttons no longer cover the
  "Players without a guild" help line; they have their own row under the /who toggles. The Next invite button's
  label is readable again when no invite is ready (dimmed like the other toggles).

## 0.22.1 — 2026-10-07

### Changed

- **Hands Free takes one step a second.** World clicks and move keys sooner than 1 second after Hands Free's
  last step do nothing (`/talod guild handsfree why` shows them as "too soon"), so fast clicking or walking
  no longer fires a burst of whispers and invites. Your recruit key, the Next invite button and clicks on the
  list are not slowed.

## 0.22.0 — 2026-10-07

### Added

- **Set your recruit key from TALOD.** Right-click the **Next invite** button (or use "Set recruit key" in Guild
  settings, or `/talod guild key`), then press the key or mouse button you want (side buttons and the wheel
  work; Escape cancels). One press = the next queued invite, else a /who, else a whisper. This works even where
  the game's Key Bindings window does not list TALOD's binding. Out of combat; it replaces your previous recruit
  key, and chat says what else that key did before.

## 0.21.0 — 2026-10-07

### Added

- **Invite queue.** Every invite still owed waits in one queue, oldest first: delayed invites, invites the
  game did not take, and invites it blocked from Hands Free. Each accepted click or key press sends one: a red
  row, the new **Next invite** button (Recruit tab and mini window, with the count), Hands Free, or the new
  key binding.
- **Key binding "Next recruit step"** (Key Bindings > AddOns > TALOD): one press = the next queued invite,
  else a /who, else a whisper to the next player. Always on, Hands Free or not; a key press is something
  the game always takes, so it can invite and search. Also `/talod guild next` for macros.
  **Needs a full game restart** (not just /reload) the first time, so the game finds the binding.
- **Tooltips that say why.** Hover a red row to see why its invite waits (delayed invite, the game did not
  take it, blocked from Hands Free, left from before a reload) and its place in the queue; hover Next invite
  for what is ready, what comes soon and what waits for its message; hover Hands Free for what it is doing,
  what the game does not take from world clicks or keys, and your binding.

### Changed

- **Delayed invite off:** the invite still goes in the same click as the message; when the game does not take
  it, it waits in the queue and is ready as soon as your message is out (it used to leave the player
  uninvited). A double click on the same player counts as one invite.

## 0.20.4 — 2026-10-07

### Fixed

- **The /who button no longer looks stuck with Hands Free on.** The game drops a /who sent from a world
  click without a word, but the button still started its 5-second wait each time. Now a Hands Free /who
  that gets no answer gives the button's wait back after 4 seconds, and after two in a row world clicks
  stop sending the /who (until you reload); the /who button always searches. The game also blocks guild
  invites from world clicks: world clicks are best for the whispers, and invites go from your click on
  the red row.

## 0.20.3 — 2026-10-07

### Fixed

- **Red rows no longer get stuck with Hands Free.** When the game blocked Hands Free's invite to a red row,
  Hands Free kept trying that same player and the row stayed red until something else moved them on. Now
  Hands Free tries a player only once: their red row waits for your click (its tooltip says so, and chat
  says it once), your click sends the invite right away, and Hands Free goes on with the others.

## 0.20.2 — 2026-10-07

### Fixed

- **No red "invite" rows with Delayed invite off.** When an invite did not go (the game held it back as a
  repeat, or blocked a Hands Free invite), the player could come back as a red delayed-invite row, often
  after a reload. With Delayed invite off they now stay a normal row marked not invited; your message
  already went, so the next click sends the invite alone. Players who were mid delayed invite when you
  turned it off also come back as normal rows after a reload.

## 0.20.1 — 2026-10-07

### Fixed

- **Hands Free no longer turns itself off.** One action the game blocked (even one that was not Hands
  Free's) switched it off for good. Now only a refusal during Hands Free's own step counts; it shows in
  `/talod guild handsfree why`, a blocked invite puts the player back as a red row, and only after the game
  blocks the same action from the same input three times in a row does Hands Free leave that one alone
  (e.g. /who from world clicks) until you reload, with one line in chat. Hands Free itself stays on.
- Hands Free's /who no longer waits on the game saying your rank can invite.

## 0.20.0 — 2026-10-07

### Added

- **Hands Free: your move and jump keys count too.** With Hands Free on, a press of a key bound to moving,
  turning, strafing or jumping (WASD and Space, or whatever you bound) is a click as well; the key still
  moves you. One press = one action. Setting: Guild settings, "my move and jump keys count too" (on).

### Changed

- **Hands Free has no pace of its own.** The /who runs on the first click after the /who button's own
  5-second wait (no extra 15 s), and quick clicks go straight to the next players: the message queue
  paces the whispers, as it does for clicks on the list.

## 0.19.2 — 2026-10-07

### Fixed

- **Hands Free now runs the /who.** It only searched when the recruit list was empty, so with players around
  from nameplates your clicks only ever whispered. Now a click runs a /who whenever one is due (every 15 s),
  and whispers in between.

### Added

- `/talod guild handsfree why` lists what Hands Free did with your last clicks, or why it did nothing (on a
  window, on a unit, in combat, nobody to message). The Recruit tab shows the last click's result too.

## 0.19.1 — 2026-10-07

### Fixed

- **Rank changes the game refuses no longer look like they worked.** When the game keeps a rank change to its
  own guild window, the menu (and the Promotions tab) now says so in chat instead of doing nothing, and those
  ranks are greyed out with the reason from then on (until the next game patch, when it tries again).

## 0.19.0 — 2026-10-07

### Added

- **Hands Free recruiting** (Guild window, Recruit tab; the mini recruit window; Guild settings;
  `/talod guild handsfree`). While it is on, a left- or right-click on the open world (not on a window,
  a player or an NPC) counts as your click on the recruit list: it invites the next red row, else
  whispers the next player, else runs a /who (at most one every 30 s). One action per click, nothing
  ever goes on its own, and it pauses in combat. If the game refuses the click, Hands Free turns
  itself off and says so.

## 0.18.3 — 2026-10-07

### Changed

- **Recruit tab, Name alphabets:** Latin is now a button like the other alphabets (the separate "Latin only"
  button is gone). Each of the ten alphabets can be hidden or shown with one click.

## 0.18.2 — 2026-10-07

### Changed

- Main menu: every page has a clearer description of what it is for, and hovering a tile or a page in the
  list on the left shows what each of its tabs holds.

## 0.18.1 — 2026-10-07

### Changed

- Right-click menus now share one look across the addon: a title with a line under it, the current choice
  marked, warnings in red, and greyed-out entries that say why when you hover them.

## 0.18.0 — 2026-10-07

### Added

- **Change a member's rank with a right-click** in the Guild window (Roster, Activity, Recruiters, Members and
  Promotions). A small menu opens just above the pointer with every rank in order, theirs marked; pick one to
  move that member there (one click, one change). A rank that would give them new rights (officer chat,
  invite, promote, remove members, officer notes...) says so in red; where the game does not tell a rank's
  rights, it shows **rights ?** instead of staying quiet. Ranks you cannot give are greyed out, with the
  reason when you hover them. Move the mouse away from the name and the menu and it closes.

## 0.17.1 — 2026-10-07

### Changed

- **Name alphabets moved to the Recruit tab**, in a card under the whisper message (they were in Settings →
  Guild). Click an alphabet to hide or show it; **Latin only** hides them all (again: shows them all). The
  card says how many players it is hiding.

## 0.17.0 — 2026-10-07

### Added

- **Groups window** (`/talod groups`, also in the main menu): a record of every party and raid you are in,
  one per group. Who was there (class, level, guild and rank, role, subgroup, time grouped with you,
  deaths seen, time offline and AFK), where you went and for how long, the group's chat and the loot.
- **Now** tab: your current group, live (health, dead / offline / AFK), to size up players mid-raid.
- **Parties** and **Raids** tabs: search a name to find every group you shared with that player; open one
  for its members, chat, loot and timeline.
- Settings → Groups: turn recording, chat or loot off, and choose the loot quality to keep. Settings →
  Data has a cleanup rule for groups older than a year.
- Two new files: **restart the game** (a /reload is not enough) after updating.

## 0.16.0 — 2026-10-07

### Added

- **Replies: each conversation is tagged Joined, Declined, Invited or Blocked**, with a filter button for each
  above the list. Blocked means they have you on ignore; Declined covers a declined invite and "Said no".
- **Replies: search the messages.** A second search box finds conversations by words said in them (the list's
  own box still searches names); the line found is shown under the name and marked in the open conversation.
- **Opening a conversation updates the player's level** (and class, race, zone): from the guild roster if they
  joined, from a nameplate, target or group member showing them, else with one /who for that name. The level
  now shows next to each name in the list.

## 0.15.0 — 2026-10-07

### Added

- **Recruit by name alphabet.** Settings → Guild → Name alphabets hides players whose names are written in
  Cyrillic, Greek, Chinese characters, Japanese kana, Korean, Thai, Arabic, Hebrew or other scripts.
  "Latin names only" hides them all in one click; names with accents (é, ö, ß, ñ) still count as Latin.
  Everything is shown until you change it.

## 0.14.1 — 2026-10-07

### Fixed

- **Replies no longer stick on "sending...".** The game sends a whisper back with swear words starred out
  ("@#$%"), so a reply with such a word stayed marked as sending for a minute after it was delivered.

### Added

- **Replies shows when a player has you on ignore.** A reply to them is marked "not delivered: they have you on
  ignore" instead of "sending...", and the conversation's status line says "has you on ignore since ..." until
  they whisper you again. A reply to a player who went offline is marked "not delivered: they are offline".

## 0.14.0 — 2026-10-07

### Changed

- **About half the memory for the same data.** Records that are kept but rarely change are now stored in a
  compact form: recruits whose invite is settled (no reply, nothing unread, untouched for 3 days), each item's
  earlier Auction House prices, and the guild event log. Nothing is lost: everything reads back the same, and a
  recruit record opens up again as soon as something about them changes. Measured on a big recruiting account:
  guild data 22 MB to 12 MB, prices 8.6 MB to 4 MB. Your existing data is converted at the first login.

### Added

- **The archive: old data off to the side, not deleted.** TALOD now comes with a second addon,
  **TALOD_Archive**, which the game only reads when it's opened. With *Move old entries to the archive instead
  of deleting them* (Settings, Data, Archive; on by default), the cleanup rules for recruit messages, price
  history, unseen items and the guild event log move what they remove into it. The archive is loaded by a click
  (Load archive, Move now) or by the daily cleanup once 2000 entries are waiting, and then stays in memory until
  you /reload. While it's loaded, price history and graphs include the archived prices. Without the archive
  addon installed, the rules delete as before.
- **Cleanup rule for the guild event log** (older than 360 days by default). Recruiter stats then start at the
  cutoff.
- `/talod archive` (state and what waits), `/talod archive load`, `/talod archive move`.
- `tools/data_report.py`: run it with Python 3 to see what fills your saved data (largest first, about what it
  costs in game memory) and what is in the archive; `--export <folder>` writes the archive out as JSON. It
  only reads the files.
- **Install both folders**: TALOD and TALOD_Archive go side by side in Interface/AddOns. Restart the game after
  updating (new files).

## 0.13.0 — 2026-10-07

### Added

- **Settings, Data: cleanup and memory.** The game loads all saved data into memory at login, so big
  logs cost memory and loading time. Cleanup rules remove what is old and no longer read, each with its
  own age and an on / off switch: opening whispers to recruits who never answered (who invited them,
  when and how it ended are kept), price history older than 60 days (the latest price and the price
  graph's daily summary are kept), items not seen on the Auction House for 180 days, and unreadable
  entries set aside at login. Each rule shows how much it would remove now; **Clean up now** runs them
  once.
- **Automatic cleanup**, once a day, 30 seconds after login, never in combat. It is on for a new
  install. **If you updated, it stays off** until you turn it on, so nothing you had is deleted
  without your say.
- **Memory cap** (150 MB by default): one warning per session when the addon's memory passes it, and
  a cleanup run if automatic cleanup is on. The Memory page shows the figure and which kinds of data
  take the most room.
- `/talod clean` (what each rule would remove), `/talod clean now`, `/talod clean auto on|off`,
  `/talod memory`.
- New file: restart the game (not just /reload) after updating.

## 0.12.0 — 2026-10-07

### Fixed

- **Less frame lag while recruiting with a long history.** With thousands of recruits on record, every click,
  every reply from the game ("You have invited...", "declines...") and the Recruit tab's redraw each second counted
  your unread replies by reading every recruit you ever invited. That count is now kept until a conversation
  actually changes. The Invited and Replies tabs no longer sort the whole list again on every change (one moved
  player is put in place), and the Replies list formats only the conversations you see.
- **Character window, Professions: no lag on every redraw.** The leveling plan was worked out again each time the
  window redrew; it is now kept until a price, your skills, your recipes, your bags (when counted) or a planner
  setting changes, and a rebuild runs a little each frame.
- Price lookups are faster everywhere (Market, Auction desk, crafting costs).

### Added

- `/talod perf`: a copyable list of the slowest work TALOD did this session (window redraws, list builds,
  events). If something still lags, reproduce it, then send this list with your report. `/talod perf reset`
  starts over.

## 0.11.2 — 2026-10-07

### Changed

- The game's AddOn list now shows NotInTheBand as the author.
- `/talod audit` is the only word for the Audit page; the old short alias is gone.

## 0.11.1 — 2026-10-07

### Changed

- The addon folder is now `TALOD` (`TALOD.toc`), and its saved data is `TALOD.lua`. New file names: restart the
  game (a /reload is not enough).
- `/talod` is the only slash command; the older short aliases are gone.
- Credits page: the "Built on" card is now "Data sources": where the game data comes from.
- Audit: the money-text reader, the statistics request and the activity assessment are rewritten. Activity now
  reads six areas (questing, fighting, dungeons, crafting, fishing, trading) with new thresholds.

## 0.11.0 — 2026-10-07

### Changed

- **The addon is called TALOD** ("That's A Lot Of Data", say "tah-lod"). The slash command is `/talod`.
  The AH helper macro is `/click TALODAHNextButton`. Guild sharing works between members on this version or later.

## 0.10.0 — 2026-10-07

### Added

- **Market: Bids tab.** Auctions you saw on the Auction House whose next bid is under the item's price, the ones
  ending soonest first. Each row shows the latest time it can end ("by 14:30", from the game's time-left band when
  you looked), the next bid, the item's price (the lowest buyout, or the usual price when that is overpriced) and
  what you save. Your own auctions are left out; "you are the high bidder" and "has bids" are marked. Items with
  no price yet are listed apart, never as a saving. Filled from your searches and full scans; nothing is searched
  for you, and bidding stays the game's Bid button. Others can outbid you until it ends: check before you bid.
  On WoW Forever, stackable goods (commodities) cannot be bid on, so only single items show here.

## 0.9.5 — 2026-10-07

### Fixed

- **Auction desk Listings: "deposits at stake 0c"**: the Auction House's own list of your auctions has no deposits,
  so they all counted as nothing. Each listing now takes the deposit you paid from your posting log; a listing the
  log doesn't have gets an estimate from your usual deposit rate, shown apart as "about ... (estimated)".
- **Posting several of an item that doesn't stack (WoW Forever)**: 20 pants posted at once were logged as one
  auction of 20 at the price of one, with only the first deposit charge. They are now 20 auctions, each at its price,
  with the deposits shared out evenly; the late deposit charges are no longer filed as bids. Posts made before this
  update keep their old entries.

## 0.9.4 — 2026-10-07

### Fixed

- **Auction desk Overview: "worth ... after the cut" still too low after 0.9.3**: the game gives every stack you
  list at its price per unit, and stacks were still divided by their size. Now read as the game gives them. Your
  saved listings from before are cleared once; until you open the Auction House's Auctions tab again, the desk
  uses your posting log, which had the right prices.

## 0.9.3 — 2026-10-07

### Fixed

- **Auction desk Overview: "worth ... after the cut" far too low**: on WoW Forever, listings of stackable goods
  (fish, cloth, herbs) were read as their per-unit price divided by the stack size again, so a stack of 40 fish
  counted as nearly nothing. The same wrong price showed in the Listings tab and its undercut checks. Open the
  Auction House's Auctions tab once to read your listings again.

## 0.9.2 — 2026-10-07

### Fixed

- **Craft tracker said "you cannot make ... yet" for a recipe you know**: a pattern learned while
  the profession window was closed (e.g. bought on the Auction House) counted as not learned until
  the window was opened again. Recipes are now recorded the moment you learn them, the game's own
  spell list is asked when the saved list misses one, and Craft next leaves the decision to the
  profession window.

## 0.9.1 — 2026-10-07

### Removed

- **Sort buttons that the column titles replace**: Market Prices and Crafting, Auction desk Margins and Control.
  Click a column title instead. Lists open in their usual order: Prices newest look first, Crafting, Margins and
  Control most profit first. Two orders had no column and are gone: Prices by supply, and Control by newest look.
  Crafting's "can make now" order is covered by Show: In my bags.
- **Audit, Characters**: the Order list keeps only Flags, Other sources and Level; the other orders are columns.

## 0.9.0 — 2026-10-07

### Added

- **Market window → Auction House**: while the Auction House is open, clicking an item in the Market window
  (Prices, Sell, Crafting, Deals, What sells) also searches it in the Auction House window, switching it to
  the browse view so its auctions show there. One search per click; nothing happens when the AH is closed.
  Setting: Market settings, "Click an item in the Market window: search it on the open Auction House" (on).

## 0.8.2 — 2026-10-07

### Fixed

- Materials in the **reagent bag** (Forever) are now counted: the craft tracker, the Market's "make N" and Sell
  list, and the economy log read it, so counts match bag addons such as EllesmereUI Bags that show every stack
  of an item merged into one. Classic Era is unchanged (its bag 5 is a bank bag and is never counted).

## 0.8.1 — 2026-10-07

### Changed

- Market Crafting tab: a click selects a recipe (its detail on the right); a **double-click** opens its craft
  tracker window.

## 0.8.0 — 2026-10-07

### Changed

- **Column titles over every list that has columns.** The "(materials, profit, margin)" notes after a
  section name and the "Columns: ..." lines under lists are gone: each column now has its title right
  above it (Market, Auction desk, Audit, Fishing spots and sessions, Guild activity / recruiters / shared,
  profession shopping list and craft log, Skills). The name stays first.
- **Click a column title to sort** the rows under it: once (numbers high first, names A-Z), again the other
  way, a third time back to the usual order. Each section sorts on its own; unknown values ("-", "?") stay
  at the bottom either way. The sort is kept while the window refreshes.

## 0.7.0 — 2026-10-07

### Added

- **Craft tracker** (needs a game restart: new files). Click a recipe on the Market's Crafting tab and a
  floating window opens for it:
  - What it takes and the **cheapest route**: each part is bought at its best known price, or made when your
    character can make it and that is cheaper. Parts you can't make are bought, with the reason shown (skill
    too low, not learned).
  - Per material: how many are in your bags, how many are **in the mailbox from the Auction House** (a buyout
    counts as soon as the money leaves), in other letters, and what you still have to buy and its cost.
  - The crafts in order, and **Craft next**: one click starts the next step whose materials are in your bags,
    with its count (open the profession window first). The next click starts the next step; nothing is
    crafted on its own.
  - Set how many to make with - / + (Shift: five), **Track it** to follow it, **Stop tracking** when done.
    Crafts you make count as done.
  - The Auction House helper's "Search next" list starts with what the tracked craft still needs to buy.

## 0.6.0 — 2026-10-07

### Added

- Market **Crafting** tab, expanded: a recipe list beside a detail panel.
  - Choose **Show**: all recipes, profitable only, or only those your bags hold the materials for. **Sort** by most
    profit, best margin, crafts your bags cover, or name.
  - Each row shows materials cost, profit and margin, "make N" when your bags cover it, slow / doesn't-sell
    tags, and "once a day" for cooldown recipes (transmutes, Mooncloth), which are now listed too.
  - Recipes whose product you have not seen on the Auction House are listed under their own header (search them
    there) instead of only being counted.
  - The detail: the product's price graph; per craft materials, what it sells for after the cut and your sell
    rate, profit, margin and vendor price; its market (lowest, usual, supply, how fast it sells); each material
    with its price and where it comes from, how many you have, and "make it" when crafting it yourself is
    cheaper; how many crafts your bags cover (and their profit) or what one craft still needs bought; the
    recipe's skill-up colors. Click the product or a material to open its prices.

## 0.5.0 — 2026-10-07

### Added

- Market Prices tab: the **crafting price** of items you can make. The detail shows a "Craft" line (the
  cheapest recipe's materials per item, at the best known prices) with how it compares to the lowest buyout
  now; list rows show "craft ..." (green when crafting is cheaper, "~" when a material is priced only by
  Wowhead's average). An item with a material nobody has a price for shows no craft price. "Made by" now
  also shows the cost per item for recipes that make more than one.

## 0.4.2 — 2026-10-07

### Changed

- Guild Replies: a reply you send now shows in the conversation right away, marked "sending...", until the
  game delivers it (behind queued openers that can take a while). A whisper still waiting for the game's
  message pace shows as waiting, and one the game dropped is marked "not delivered" so you can send it again.

## 0.4.1 — 2026-10-06

### Changed

- **Market prices are no longer pulled up by overpriced looks.** When the cheap auctions of an item have
  sold and only an overpriced one is left, that look used to push the "usual" price far above what the
  item really sells for. The usual price is now the middle (median) of your looks. Any look more than twice
  that is marked **overpriced**: red in the price graph, flagged in the look list and the Prices tab.
  It stays in your history but is left out of the usual price, the trend, deals, the sell value, the
  suggested posting price and crafting profit. When your latest look is overpriced, selling counts the
  usual price.
- Auction desk: a relist never aims at an overpriced listing. Ladder tiers over twice the usual price
  are marked, "own it all" relists under them, and a reset that relists at that price is never offered
  as the best one.
- Prices from the Auction House's browse list are marked as rough. While you have exact looks (an item's
  own listings, a scan), rough looks never set the usual price.

## 0.4.0 — 2026-10-06

### Added

- **Saved data check.** At every login the addon checks its saved file. An entry it cannot read (from a
  hand edit or a damaged file) is set aside instead of breaking a window, and you are told once.
  `/talod data` (or Settings → Advanced → Saved data) lists what is kept, for the whole account and for
  each character, and shows anything set aside (`/talod data clear` deletes those).
- **Every log now records which of your characters gathered it**: sightings, census points, auction
  prices and ladders, fishing casts and attacks, the guild roster log, recruit conversations, guild chat
  activity and Audit looks. Fishing casts from before this are matched to their fishing session; other
  older entries stay "unknown" rather than being guessed.
- **Tamper seal on what you share with officers** (recruiting, play time, profession ranks). It is
  sealed when you log out. If the saved file is changed outside the game, officers see "edited" next to
  what you share. A file copied from another account shows up the same way. Your data stays readable;
  nothing is encrypted.
- Officers: what members share is checked before it is shown. Impossible values (a level the game does
  not have, more play time than hours in the week, profession ranks the level cannot train) are dropped
  and listed. Claims the guild's own records contradict are marked: a level different from the roster,
  a recruit missing from the guild event log, an "alt" who is not in the guild. The Members tab uses the
  roster's level, and its tooltip says the figures come from the member's addon.
- Audit: a new **"Shared figures the server contradicts"** flag, raised when a member's shared
  statistics disagree with the server's figures from an inspect (counters that only go up).

New file: restart the game (a /reload is not enough).

## 0.3.0 — 2026-10-06

### Added

- Guild window: a new **Activity** tab for the guild master and officers (the game's own rank
  permissions decide; other members don't see the tab). It shows who talks in guild chat and who
  doesn't: lines and last line per member, and the days each one was online while you were.
  Members are *active* (said something in the window), *quiet* (online with you but silent) or
  *not seen* (neither, so unknown, never counted as quiet). Window of 3 / 7 / 14 / 30 days,
  filters, Shift-click Clear. Only chat seen while you are online counts; nothing is sent anywhere.
  `/talod guild activity` opens it. New file: restart the game (a /reload is not enough).

## 0.2.2 — 2026-10-06

### Fixed

- Less frame lag in crowded places. The census and the guild recruit scan read every player in sight
  in a single frame once a second, a stutter in cities and battlegrounds; they now spread that over
  the second. Enemy nameplates are no longer read in full four times a second (name, class, race and
  guild are read again every 5 seconds; level, PvP flag, death and hostility still every update), and
  the parts of the addon that look at the same player or target now share one read.
- The addon no longer listens to every unit's health changes or every unit's spell casts (hundreds a
  second in a battleground) where it only needed your target or yourself, and its error guard no
  longer creates garbage on every call.

## 0.2.1 — 2026-10-06

### Fixed

- Guild window: clicking a player on the Recruit tab (or in the mini recruit window) no longer
  stutters for a frame. The redraw after each click read your guild over a hundred times when many
  players were listed; it now reads it a few times.

## 0.2.0 — 2026-10-06

New files: restart World of Warcraft (not just `/reload`) after updating.

### Fixed

- Fishing: the weapon swap button now equips both weapons when you dual wield two copies of the same weapon
  (two identical daggers). It used to equip only the main hand: the game's `/equipslot` cannot tell two copies
  apart. The second copy now comes from its own bag slot (helper `/click TALODFishingOffHandButton` inside
  the swap macro; still one click, one swap).

### Added

- Guild, Replies tab: a **Report** button opens the game's report window on the player's last whisper. You pick
  the reason and send it there. It works when they ignore you, and while "Keep recruiting chatter out of chat" keeps their lines
  out of the chat window. For whispers from before your last login or reload, it reports the player instead.
- Guild, Replies tab: a **Said no** button for players who turn you down in a whisper. Their delayed invite no
  longer comes back for your second click, and they are never offered as a recruit again. They show as "said no"
  in the Invited tab. "Undo no" takes it back.

### Changed

- Main windows (Character, Economy, Market, Auction desk, Fishing, Guild, Audit, Settings, Credits and the
  Main menu) now share one size, so switching pages no longer changes the window's size. Drag the three
  lines in the bottom-right corner to make it bigger or smaller; the page fills the new size (the fishing
  heat map grows with it). Double-click the corner to get the default size back. A settings reset does too.
- Item tooltips: TALOD's lines now sit under one TALOD header as "Auction" and "Sells" rows, with
  the details lined up on the right, instead of "TALOD AH" and "TALOD sells" each on their own.
- Every TALOD tooltip (panel, minimap button, settings, windows, charts) now uses the same line styles and
  colors. Warnings in the enemy tooltip ("Targeting YOU", "PvP flagged", "PvP: ?") follow the colorblind
  setting.

### Under the hood: one tooltip file

- `Tooltip.lua` builds every tooltip and owns the item-tooltip hook; modules add their lines to it. New file:
  restart the game.

### Under the hood: the addon's name in one place

- The name (shown text, window and button names, popups, slash commands, saved data, guild-sharing prefix)
  now comes from one file, `Brand.lua`, ready for a future rename. Nothing changes for you: same commands, same
  macros, same saved data.
- Every slash command, its aliases and its help line are now one list (`Commands.lua`). `/talod help` is built
  from it, so it now lists every command (fishing, guild, audit ...) in one order. A mistyped command shows help.

### Credits page

- A new Credits page (Main menu, the page list, or `/talod credits`): who made TALOD, the Discord invite
  (https://discord.gg/2FYCFyRczN) and, if you want to support it, the character to mail gold to: Send Coin
  (Alliance, PvP realm). Copy buttons put the link or name in a box ready for Ctrl+C.
- Every copy button (Credits, the guild Replies tab's Copy username) now uses the same copy box.

### Recruiting: invite answers fixed, and a way to check delivery

- Declines, "offline" and "already in a guild" now update the recruit even when the game writes the name
  differently from how it was saved (for example without the realm). Before, those lines were hidden from chat
  but the status stayed "invited".
- A player who is offline when your message goes out is marked offline and does not come back to invite.
- A decline now counts up to 15 minutes after the invite (was 2).
- The game's "You have invited X to join your guild" now confirms each invite. If it never comes within a
  minute, the Invited tab shows the player as **unconfirmed** (gold, counted in the title): the invite may not
  have reached them, and a click invites them again. Replies shows "confirmed" next to the status.
- `/talod guild check`: your invites of the last hour (sent, confirmed, answered, joined, unconfirmed by name),
  and any game line right after a send that TALOD did not recognize, to report.

### Recruiting: your message first, then click again to invite

- **Delayed invite** (on by default; button next to /who on the Recruit tab and in the mini window, and in
  settings). The first click on a player whispers your message and takes them off the list. 10 seconds after
  the message went out, they come back below the players you have not messaged yet, with a **red** bar: click them again to send the guild
  invite. Players you have not clicked yet have a **gray** bar. With it off, one click sends the message and
  the invite together. Without a message (setting off, or Invite again in Replies) the invite goes at once.
- Fixed: the invite that was meant to follow 10 seconds later on its own never went out. The game only allows
  a guild invite from your own click, so it was blocked (BugGrabber showed "TALOD tried to call the
  protected function"), and the player was still marked invited.
- Inviting a run of players no longer drops your message: whispers past the game's pace (about one a second)
  wait in a queue and go out in the order you clicked. The Invited tab shows "message queued", "invite in N s"
  and then "click to invite"; click a queued row to send its message right away. While the game is limiting
  your messages, they wait for the pause to end.
- A waiting message is not sent if you forget or skip that player meanwhile. If the game refuses the invite,
  or you `/reload` before the message went, the row shows "not invited": one click invites (without whispering
  again). `/talod pace` shows how many messages are waiting.
### Auction gold from the mailbox is always named

- Taking gold from several letters quickly (Open All, or clicking one letter after another) no longer
  leaves an unnamed "Mail" entry. Each letter's gold is now matched to that letter, so every sale shows
  as "Auction sold: item", with the right amount, and closes the right listing.
- A sale letter with no buyer name no longer reads "to " at the end.

### Market, Auction desk and Economy open without a lag

- The first click on these windows no longer stalls the game for a moment. Their numbers (and the
  Auction desk's plan for every item after a full scan) are now worked out quietly a few seconds after
  login, a little each frame and never in combat.
- With a window open, a new price or a sale no longer freezes it while the big lists are redone: it
  shows the previous numbers for a moment and updates when they are ready.
- Clicking a recruit (invite or never offer again) no longer freezes the game for a frame: only the
  guild windows are redrawn, once, instead of every TALOD window twice. The same goes for /who,
  forgetting a recruit and the game's reply to an invite.

### One outbox for whispers and invites

New file (Outbox): restart the game, not just `/reload`.

- Every whisper and invite the addon sends now goes through one queue, so new features that whisper share the
  game's message limit with guild recruiting instead of tripping it separately. When the game says it is limiting
  your messages, all whispers pause together.
- A double click while the game lags no longer sends the same guild or party invite twice.
- `/talod pace [reset]` shows (or forgets) the learned whisper limit; `/talod guild pace` still works. The limit you
  already learned is kept.

### Audit: members' gold and activity

New files (Audit, AuditUI): restart the game, not just `/reload`.

- A new **Audit** page (main menu, page list, `/talod audit`): the game's own statistics for you, players
  you inspect and guild members who share theirs: total gold acquired, most gold ever owned, gold
  from loot / quests / vendors / auctions, auction counts, quests, kills, dungeons, deaths, profession
  ranks. The last 20 looks of each character are kept, with what changed between them.
- Tabs: **Members** (your roster with what is known of each, flagged first), **Flags**, **Characters**
  (everyone on record, sortable), **Ledger** (one character) and **History**.
- **Flags** for records worth a look for bought gold: most gold owned above all recorded income,
  a large share of income from neither loot, quests, vendors nor auctions, sudden unexplained gold
  between two looks, peak gold high for the level, gold without much play. Thresholds in the
  settings (Audit). A flag is a reason to look, not proof; a missing counter never counts as fine.
  Officers can mark a record "Looked: fine" (a new flag brings it back), put it on watch, and add a note.
- Reading another player: the Audit button on the Inspect window, the Target button, or on every
  Inspect (setting, on by default). One request per click, 5 s apart, never retried on its own.
- Guild sharing has a new Yes / No line, "Gold and activity statistics": nothing is sent before a
  Yes, it goes only to the officer who asks, and a No later removes the officers' copies. The gold
  you carry is never shared.
- WoW Forever only (Classic Era has no statistics). When another addon also asks for statistics, the two
  take turns with the game's single request.

### Big logs stay fast

New file (Data): restart the game, not just `/reload`.

- The Economy window no longer lags with a long history: lists format only the rows you see, totals
  and lists are worked out again only when something new is recorded, and looting many things in a
  row redraws the window once a second at most. "Gold over time" is worked out much faster.
- The Market window no longer lags after a full scan or while you browse the Auction House: the price
  list is kept until a price changes, and result pages redraw it once a second at most.
- The same now holds for every window over a long history: Auction desk, Guild (Invited, Roster, Log),
  Character (Ledger, Sources, Skills log, Crafting) and Fishing (Spots, Log, Sessions, Goals). The
  Goals tab no longer reads your whole cast log on every redraw.

### Navigation

New file (Navigation): restart the game, not just `/reload`.

- Main menu: a page for every TALOD window (character, economy, market, auction desk, fishing,
  guild, settings) and an Enemies nearby panel switch. Left-click on the minimap button, the addon
  compartment entry, or `/talod menu`.
- Every main window has the same page list on its left: one click switches to another window.
- Only one main window is open at a time; the next one opens where the last one stood (drag it by
  its title bar or the page list). Side windows (Auction House helper, report, mini recruit window,
  HUD) stay open beside it. `/talod reset` puts the windows back in the middle.
- Minimap left-click now opens the main menu instead of the character window; the Shift / Alt /
  Ctrl / right-click shortcuts are unchanged.

### Auction House

- Full scan no longer gets stuck or ends without a word. Before, the check for the server's answer
  (and the 90-second timeout) only ran while the scan panel was shown, so closing it (Escape) with
  the Auction House still open left the scan waiting for good. An error while reading the answer
  left it on "Reading..." for good too. Now the check runs in the background, a read that errors or
  stops for 30 seconds ends as "Full scan failed" with the reason, and every scan shows in
  `/talod ah log`.

### Guild

New files (Guild, GuildUI): restart the game, not just `/reload`.

- When the game says "The number of messages that can be sent is limited", whispers pause (15 s, longer
  if it happens again soon) and invites go without the message meanwhile. Players whose message was
  dropped or held show "no message" in the Invited tab: click the row to send it (one whisper). Your
  whisper limit is lowered to stay under the game's from then on (`/talod guild pace`, `reset` to undo).
- Replies tab: Invite to party, Add Battle.net (the game's friend request; for guild members and the
  player you target) and Copy username buttons under Delete / Invite again.
- Fixed the opening whisper showing twice in a conversation. The game sends about one whisper a
  second, so in a long run of invites the opener arrived minutes late (sometimes after the player
  had already joined) and was kept again. Old conversations are cleaned up once. When whispers are
  more than about 10 seconds behind, the invite now goes without the message and chat says so.
- The guild window no longer lags in a big guild: only the Recruit tab redraws every second; the
  other tabs redraw when the roster or the guild log actually changes, and the recruiter history is
  worked out once instead of several times per redraw.
- Recruit: players of your faction without a guild near you (nameplates, target, mouseover) and from
  `/who` (one search per click) are listed. One click sends your whisper and the guild invite;
  right-click hides a player for good. Write your own messages in the window.
  Filter the list by name (search box), level (Lv buttons, shared with /who) and class (one chip per
  class; right-click a chip for only that class).
- Invited: everyone you invited and how it went (joined, declined, offline, already in a guild,
  replied).
- Roster with last online and inactive members; Promotions with rules per rank and one-click
  promote; Log of joins, leaves, removals and rank changes.
- `/who` searches your whole level range in one click (up to the top level the game reports, read live: it follows
  when Forever raises its cap) and only splits it into smaller ranges when the answer is full; at most one search
  every 5 seconds (the button counts down).
- Mini recruit window: the Recruit list (same filters and clicks, plus /who) in a small movable window
  that stays on screen. Off by default; Recruit tab button, settings, `/talod guild mini`.
- Replies fixes: the same short reply sent twice ("ok", "yes") shows twice (only the game's echo of your
  opening whisper is skipped); whispers whose name comes without the realm (or in another form) still
  reach the conversation; a long conversation redraws on every new line at once; a line the game hides
  shows as a note instead of being dropped.
- No double whispers: the same text to the same player within 10 seconds is sent once (a second Enter or
  click while the game lags). When the game refuses an invite, a quick second click sends only the invite,
  not your whisper again.
- Replies: whispers with players you invited, with unread counts, a reply box and a small notice; they
  and the game's invite / decline lines stay out of the chat window (setting).
- Recruiters: who invited whom from the game's guild log, kept past what the game keeps: joined, still
  here, left within 7 days, joined more than once, average days. Promotion rules can ask for recruits kept.
- Names with a first and a last name (WoW Forever) work everywhere: lists, whispers, invites, messages
  (`{first}` is the first name). Fixed: a player seen on a nameplate and in /who was listed twice and
  could get two invites; plate invites went to "First-Surname" (most likely not found by the game) and never got the
  game's answer. Old double records are merged on first login.
- Replies: your opening whisper is kept when it is sent (it went missing for players first seen on a
  nameplate), and missing ones are put back from the saved text. The tab lists only players who wrote back.
- Chat: only the recruiting spam is hidden (your opening whispers, invite / decline lines, answers you have
  not written back to). Your own replies, and the conversation after them, show in chat again.
- Sharing (new file GuildSync: restart the game): members choose what officers may see (recruiting,
  other characters, level and professions, play time); nothing is sent before a Yes, only to the asking
  officer, and a No removes it from the officers' addons. Members tab for officers, Sharing tab for
  everyone. Officers' promotion rules reach members, who see their own progress.
- `/talod guild`, Guild settings page, minimap Shift + right-click.

### Fishing: swap back from the HUD

- Click the HUD's Weapon line to equip your weapon (and off hand) again, with or without an enemy
  in view. Out of combat; in combat the swap button under the HUD still works. Setting: Fishing >
  Safety > "Click the HUD's Weapon line to equip my weapon".
- The swap button under the HUD was hidden behind the apply-lure button when both showed; it now
  sits below it.

### Fishing sound

- Sound stuck after the loud splash? `/talod fish sound` checks each setting it changes (effects, music,
  ambience, background sound) and says what it goes back to; `/talod fish sound reset` puts back your
  usual sound (or the game's default when TALOD never saw your usual); `/talod fish sound default`
  sets the game's defaults. Also buttons on the Fishing settings page. The master sound switch is
  only reported, never changed (Ctrl+S).

### Auction desk

New files (AuctionDesk, AuctionDeskUI, PriceChart): restart the game, not just `/reload`.

- Price graphs with volume: the lowest price over time (per look, or per day with the day's
  highest as a band), the usual price, units listed as bars and the units you sold in green.
  Hover a point for its date, price, units listed and how many fewer than the time before (sold,
  cancelled or expired: the Auction House does not say which). In the Market window's Prices
  detail, the desk's Control tab, and under item tooltips at the Auction House (Skills > Auction
  prices: also everywhere, or off).
- Prices keep a daily summary (lowest, highest, most units listed) for 60 days, so the graph goes
  back past the last 30 looks. Data logged before this starts with those 30 looks.
- Does it sell? Every item tooltip says **moves fast / moves / slow / doesn't sell**, from your own
  data: your auctions of it once 2 have ended (sell rate, none ever sold, time to sell, last sold),
  else how fast it leaves the Auction House between your looks (units a day against units listed,
  how many days the supply lasts, "nothing left the AH in 3 days"). Not shown on soulbound or grey
  items, nor on items you have never seen or posted. Setting: Skills > Auction prices.
- The same verdict in the desk (Control detail, Listings, Deals, Margins) and the Market window
  (Prices detail, Sell list). Resets on items that don't sell are no longer suggested. New Overview
  section "Not worth posting": what you posted that doesn't sell, with the deposits it cost.
- Auction letters now tell when an auction really sold or ended (from the letter's arrival, not
  when you opened the mailbox): time to sell, and sell rates and graphs dated right. Auctions closed
  before this keep the mailbox time.

- `/talod ah` now opens the **Auction desk** instead of the scan panel. The scan panel still opens by
  itself beside the Auction House, and with `/talod ah scan`.
- Overview: your listings, the best resets, deals and crafts at a glance, with the full-scan timer.
- Listings: each of your auctions against the market: lowest, or undercut (units under yours, the
  lowest price, the price to repost at). Read from the Auction House's own list when it shows it,
  else from what you posted.
- Deals: how many units are listed at the deal price, what they cost and what reselling them all
  gains after the cut and the deposit.
- Margins: crafting profit and margin (profit / materials), sorted either way.
- Control: what owning an item's market costs, and "resets" (buy up to a price, relist 1c under the
  next seller) with units, cost, deposit, revenue after the cut and your sell rate, and profit.
  Shows who holds the supply when the auction house names the sellers, and the whole price ladder.
- `/talod ah <item>` prints an item's buyout cost and best reset, and opens it in the Control tab.
- Prices now keeps each item's whole price ladder when a look shows every auction of it (full
  scan, an exact search on one page, commodity / item results). A partial look gives "at least"
  costs; an old look says to search again.
- The deposit is learned from your own posts (15% of the vendor price until you post something).
- Settings (Skills > Auction prices): open the desk, and the profit from which a reset is shown.

- Enemies nearby: a button in the panel's title bar mutes enemy alerts (center text, sound,
  chat, the vanished-stealther alert and the fishing enemy sound) and turns them back on; the
  panel keeps listing enemies. The same switch is on the settings page (General > Panel) and
  `/talod alerts on|off`.

### Fishing (2026-10-04)

New files (FishingData, FishingSafety, FishingGoals, FishingGear): restart the game, not just `/reload`.

- Safety: a loud warning (with your alert sound) when an enemy player comes into view while your
  fishing pole is in your hands; the HUD's Weapon row turns red.
- Swap button under the fishing HUD: one click puts back the weapon (and off hand) you held last.
  Usable in combat once shown; bind it with `/click TALODFishingSwapButton`.
- Warning when an enemy player targets you while you fish. A target the game hides never alerts.
- The HUD shows the nearest player's range ("1 in view · 20–25 yd"); a hidden range is "? yd".
- "Got away" now means only the game's "Your fish got away!". Clicks with nothing hooked and early
  stops count as "missed" and no longer lower a spot's catch rate (casts logged before this still
  count early stops as got away).
- The cast timer and HUD bar use the channel's real length (30 s when the game does not say).
- Each cast records the server time and the lure used: spots and the fishing viewer show catch rate
  and gold per hour by lure; the viewer shows catches by server hour.
- New Spots sort "Skill-ups per hour" (most catches per hour at your skill).
- New Goals tab (`/talod fish goals`): Nat Pagle's four fish, the Stranglethorn Fishing Extravaganza
  fish and other notable catches: how many, where, at which skill, where to look, which quest.
- Zone fishing level: "Zone: needs ~X (you Y)" on the HUD, in spot details and `/talod fish zone`,
  with your hook chance when you are below it.
- Day/night and seasonal fish (Nightfin Snapper, Sunscale Salmon, Winter Squid, Summer Bass) show on
  the server clock whether they bite now.
- Stranglethorn Fishing Extravaganza clock (Sundays 14:00–16:00 server time in vanilla; Forever may
  not run it), optional chat reminder.
- Best fishing pole, hat and boots you own, with a HUD warning when something better is in your bags.
- Lures in your bags on the HUD, and an "Apply lure" button: one click puts one lure on your pole
  (`/click TALODFishingLureButton`). Hidden in combat.
- Click the HUD's Lure line to put the same lure on your pole again (the one you used last, from
  the button or your bags; one click, one lure). Out of combat only. Setting: Fishing > Gear.
  It reads the lure's bonus from your skill bonus (less your gear), so with Bright Baubles on it no
  longer picks Nightcrawlers.
- Fix: lure enchant 265 is Bright Baubles (+75), not a +50 lure (measured in game); lure labels in
  the Spots view and the fishing viewer were wrong for it.
- Fish your profession plan needs are tagged in catch lists ("needed: 8 for your Cooking plan").
- Pool casts are guessed from the pool's tooltip (English clients); spots show the pool catch rate.
- Settings: Fishing > Safety, Goals, Gear. `/talod fish safety`, `goals`, `zone`, `gear`.
- Data: zone fishing levels and goal fish from the CMaNGOS Classic DB and wago.tools, fishing gear
  and lures from Wowhead Classic, all read 2026-10-04.

### Review fixes (2026-10-04)

- Hardcore safety: the "this would flag you" warning now also covers an enemy player's **pet**
  and enemy-faction **NPCs** (guards, flight masters), which flag you when attacked.
- Economy: gold traded with one of your own characters is a transfer again (it was counted as
  spending). Several stacks posted at once are now one auction each, with its own deposit and
  sale letter, so per-unit sale prices and sell rates are right. Item quality is read from
  newer-engine links too.
- Market: a deal is measured against the usual price of your *earlier* looks (today's low price
  no longer drags the average down), and the Deals tab shows that price. Sell-through: items
  with too few ended auctions are listed as "too few to tell", never as "sells". A crafting loss
  shows a minus sign, not only red.
- Gear: comparing with, or measuring "since first" from, a snapshot taken while your stats were
  hidden no longer shows invented gains or losses; it shows `?` or uses the first readable one.
- `/talod reset` keeps every kind of logged data, including stores added later, and moves the
  fishing HUD back too. Typed names are matched like the game writes them (`/talod kos SHADOWFANG`).
- Data refreshed from the cache (no new download), checked 2026-10-04:
  - transmutes and Wizard / Mana Oils make 1 (they made 0, which hid them from the planner and
    the crafting profits); explosives count their average yield;
  - only items a vendor really sells have a vendor price (herbs, leathers, raid materials,
    potions no longer show "vendor 40c"); patterns are priced only when a vendor sells them;
  - Smelt Copper, Enchant Bracer - Minor Health / Minor Deflect, Charred Wolf Meat, Roasted Boar
    Meat, Basic Campfire and Crafted Light Shot start at skill 1;
  - raw fish are "Fishing", pearls "Clams", Runecloth and Felcloth "Cloth"; Flint and Tinder and
    the Blacksmith Hammer have names; Transmute: Elemental Fire has no cooldown.
- More enemy auras highlighted: Vanish (its buff), Deterrence.
- The census and fishing viewers now ship in `tools/`. They read damaged or unusual saved files
  (holes, inf / nan, cut-off files), find the file in other game folders (or `WOW_DIR`), and
  escape every name in the page.

- Fishing (`/talod fish`, settings: Fishing). New files `Fishing.lua`, `FishingUI.lua`.
  - Every cast is logged: where, your skill (with lure and gear), lure on or off, and the
    result: caught (with what), got away, no bite clicked, or interrupted by combat.
  - Spots (by subzone): catch rate, value per catch and gold per hour of fishing **at your
    skill** (your 25-point skill band; else data from a lower skill, which is a safe estimate),
    catch rate by skill band, the fish you caught there and their share.
  - Danger per spot: NPC attacks, player attacks and enemy players seen per minute fished
    ("one every 14 min"), deaths while fishing, the chance of 30 minutes without an attack, the
    quietest time of day, and the Census count of enemy players around that spot. With too little
    data it says "?", never "safe". The attacker is whoever targets you (turn enemy nameplates
    on); if nothing readable targets you it is "?", never a guess.
  - Map tab: a heat map of each map you fished, by casts, catches, value, attacks, enemies
    seen, or **one fish** (where it bites). It draws the zone's map art when the game provides it.
    `tools/fishing_viewer.py` builds the same as an HTML page.
  - Now tab, and a HUD that pops up while a fishing pole is equipped (and goes away when you swap it out): session time, catches and catch rate, value and gold per
    hour, skill with the catches to your next point (from your own skill-ups), lure time left,
    free bag slots, enemies in view, danger here.
  - Warnings: your lure ran out, bags almost full, skill at its maximum. Optional sound for
    every enemy player spotted while you fish (never for hidden hostility).
  - Auto loot while fishing (button on the window, settings, `/talod fish autoloot`): turns the
    game's Auto Loot option on at your first cast if it is off, and back off the moment you unequip
    your fishing pole, and at logout. The old value is saved, so a `/reload` or logout mid-fishing still
    puts it back. If you change the option yourself meanwhile, your choice stays.
  - Log tab (casts and encounters) and Sessions tab (a session ends after 5 minutes without a cast).
  - Loud splash while fishing (on by default; window button, settings, `/talod fish splash`): addons get
    no event when a fish bites, so the splash is made hard to miss instead. Sound effects go to full,
    music and ambience off, and sound keeps playing while the game is in the background. A muted game
    stays muted. Put back the moment you unequip your fishing pole, and at logout (so the game never
    saves the fishing settings as yours). The HUD shows how many seconds the current cast has run.
- Auction House helper on the newer engine (WoW Forever):
  - "Search next" types the item into the Auction House window's own search bar and runs it, so the results
    show in the window (and are logged). Before, it sent a background search the window never showed.
  - Says when the Auction House is busy, when it dropped a search, and when the game blocked a call (with
    its name) instead of doing nothing.
  - Full scan: the wait shows seconds, clicking it again cancels (the next scan can go at once), and the
    data is read even if the scan's event never arrives.
  - `/talod probe` prints an "auction house:" line with what this client offers.
  - Every full scan reports its outcome in chat: done (in N s: auctions, items, how many prices were new and
    how many changed: numbers only a real answer gives) or failed and why (no answer, blocked, refused, window
    closed, cancelled). `/talod ah log` lists the last scans; the panel shows the last result; item tooltips say
    "in the full scan 5 min ago" for prices a scan brought.
  - Fixed: the panel kept showing "Reading..." / "Waiting..." after a scan had ended.
- Fixed: `/talod reset` erased your logged Auction House prices; they are kept now (data, not settings).
- Lists everywhere: a scrollbar on every list that does not fit (drag the thumb or click the track; the
  wheel still works). The long lists also get a search box (any text in a row, colors ignored) and a time
  range (All time / Last hour / Today / Last 7 days / Last 30 days, with a dropdown), with "N of M shown":
  fishing casts, encounters, sessions and spots; Market prices (time), sell, crafting, deals and
  sell-through; Economy transactions, auctions and trades (search: they have their own range); gear
  snapshots, ledger (an entry and its lines filter together) and sources; skills and their history; the
  crafting log. Section headers stay only above rows that match.
- Fixed: prices from Auctionator showed "1 min ago" all day. Auctionator only keeps the day of its scan, which
  was read as "right now"; it also made Auctionator's price win over your own, fresher look from earlier that
  day. Auctionator prices now read "Auctionator, today" / "yesterday" / "3 days ago", and your own look wins
  unless Auctionator's scan is from a later day.
- The fishing HUD looks like the Enemies nearby panel: title bar (cast seconds, zone) with buttons for the
  fishing window and settings and a lock, a thin bar that fills as your cast runs, one row each for session,
  value, skill, lure, bags and enemies (gold accent when something needs you), and the danger here in the
  footer. It uses the panel's Size setting. Drop it next to the Enemies nearby panel (below, above or beside),
  or drop the panel next to it, and they snap together; docked, it moves with the panel. Drag it away to undock.
- Every "click to cycle" button (the ones ending in `>`: map, show, sort, skill, character, scope,
  profession, range, and the cycle settings) has a small arrow on its right that opens all choices as
  a dropdown list (current one marked, scrolls when long). Clicking the rest of the button still cycles.
- Fishing settings after a crash: logout puts sound and auto loot back, but a crash skips logout. Your
  usual settings are now kept from your last clean session; if you log in with the fishing settings
  still on and nothing to put back, TALOD asks whether to restore your usual ones (it never
  changes them without asking, in case you chose those values yourself).
- What sells and what doesn't (one rule for the Market window, the profession planner and fishing):
  - Your own auctions (every character, closed by the auction letters) give each item a sell rate:
    sold out of ended. Recent auctions count more: each counts half as much every 14 days.
  - Value = Auction House price after the cut × your sell rate (once 2 have ended), against the
    vendor price. An item that keeps expiring drops to the vendor price by itself. Soulbound and grey
    items count at the vendor price only. Fishing flags catches never seen on the AH (their value is the
    vendor's, likely too low).
  - Item tooltips: "% likely to sell" with sells well / sometimes / hard to sell, how many sold, the
    last 30 days, and when it last sold and last went unsold ("may be out of date" when nothing ended in
    30 days).
  - Market window: new **Sell-through** tab (every item you posted, worst sellers first, unsold count and
    deposits lost); the Sell tab marks "hard to sell" and totals use the sell rate; item detail shows
    your sell rate.
- Auction House helper: a panel next to the Auction House window (or `/talod ah`).
  1. Full scan: one click asks for every auction at once and logs the lowest price, the auctions
     and the units of every item (the server allows one every 15 minutes; the button counts down).
  2. Search list: the items you need prices for (your profession plan's materials, what you make
     on the way and the products; your bags; your crafting products and materials; prices over a
     day old: pick with the chips). Each click searches the next one and shows the result; items
     seen in the last 30 minutes are skipped. Bind it to a key with a macro:
     `/click TALODAHNextButton`, then press that key at the Auction House.
- Auction House prices first everywhere:
  - The planner uses your AH price for a material a vendor sells when the AH is cheaper.
  - Item tooltips: your AH price, how old, the auctions and units listed and the usual price.
  - Enhance tab: the price of every reagent, the total material cost of each option, and what
    buying the item (armor kits, spikes, ...) would cost.
  - Market: a posting price (1c under the lowest at your last look), also in the Sell tooltips.
  - Economy: loot entries show what the items are worth on the AH.
  Settings: Character > Skills > Auction prices.
- Profession plan with Auction House data:
  - "Resale: on" (default): what a recipe's product sells for (AH after the cut, or a vendor,
    whichever is more) lowers its cost when the plan picks recipes, so recipes whose products
    sell win. "You end up with" lists the leftover products and their value; the summary shows
    the cost after selling them.
  - Shopping list: how many were listed at your last look ("212 listed", red when fewer than you
    need), and materials never seen on the AH in their own group ("look them up").
  - Steps: what each product sells for; "Make" lines say what buying it instead would cost.
- Market window (`/talod price`, or Alt + click the minimap button):
  - Prices: every item you have seen on the Auction House, searchable and sortable (newest look,
    name, price, most under its usual price, supply). Per item: the lowest price now and how old
    it is, the auctions and units listed, its usual price (the average of your looks) with the
    lowest and highest, the trend of price and supply, what it nets after the 5% cut against a
    vendor, your own sales of it, Auctionator's and Wowhead's prices, the recipes that make it
    (with profit) or use it, and every look you took.
  - Sell: everything in your bags, sorted into Auction House (worth more there after the cut),
    vendor, and "check the AH" (not seen yet), with totals.
  - Crafting: the recipes of your professions you can make now, materials against what the
    product sells for, best profit first (all you can make, or only recipes you know).
  - Deals: items listed at 80% or less of their usual price (3+ looks), with the gain per unit if
    resold at the usual price.
  `/talod price linen` opens it searching for Linen and lists the matches in chat.
- Auction prices: everything the Auction House shows you (searches, browsing, an item's
  listings) is logged with the lowest buyout per unit and when you saw it, per realm and faction.
  The profession planner, its shopping list and the crafting log use these instead of estimates:
  vendor price first, then the Auction House as you last saw it (green: today, gold: this week),
  then Auctionator's price if it is installed and you have not seen the item, and only then
  Wowhead's average (grey). Hover a material for the price, its source and its age.
  Each look also records the auctions and units listed. Setting: Character > Skills
  > Auction prices.
- Minimap button (the TALOD icon on the minimap's edge): left-click the character window,
  Shift + left-click the economy window, Ctrl + left-click shows / hides the Enemies nearby panel,
  right-click the settings; drag it around the minimap. Works with round and square minimaps, and
  minimap button bars (EllesmereUI) pick it up. Settings: General > Panel > Minimap button, or
  `/talod minimap`.

- Economy window (`/talod economy`, or the coin button on the Enemies nearby panel): money for your
  whole account, or one character (button top right), over today / 7 / 30 days / all.
  - Overview: gold now (all characters; hover for each), today, the range, this session with gold
    per hour, best income and biggest cost; gold over time (hover a day); by source and per day.
  - Transactions: every change of your gold with what you were doing (vendor sales and purchases,
    repairs, loot merged per zone, quest rewards, trades, mail, auction house, training, flights,
    transfers), filterable by kind.
  - Auctions: every listing from posting ("Listed Copper Bar x20 · buyout 1g 20s · bid 1g · 24 h ·
    deposit 58c") to its end: sold (what you received and the profit after the deposit), expired or
    cancelled, from the auction letters. Bids and buyouts are named.
  - Trades: with whom and what went each way.
  - Mail and trades between your own characters are transfers: not income or spending for the
    account, but they count when you look at one character.
  - Fixed: posting an auction right after using the mailbox was recorded as "mail" (the mailbox was
    still seen as open). Only one NPC window counts at a time now, the newest wins, and the newer
    engine's interaction events are used too. Settings: Character > Economy.
- Character > Professions (`/talod plan`, or `/talod plan tailoring 225`): a leveling plan for any
  crafting profession, First Aid or Cooking, from your skill to the target you pick. Steps in order:
  which recipe to make from skill A to B and about how many (the game's skill-up chances: yellow
  and green recipes need more crafts), what to make first (bolts, bars), and when and where to
  train the next rank (with the level it needs). Next to it the shopping list: every material with
  how many you need, have (bags and bank) and must buy, with an estimated cost (vendor price or
  Wowhead's auction average), plus the tools. Recipes that need a pattern are marked (vendor price
  or "drop"); switch to "trainer recipes only", or right-click a step to never use that recipe.
  Recipes you know are read when you open your profession window.
  Data: Wowhead Classic, generated by `tools/gen_professions.py` (re-run it to pull updates).
  The plan starts at your current rank (green "from 60"; red when the game has not told us your
  rank yet). If it is out of date, set the start with - / + (click it to go back to your rank), or
  `/talod plan tailoring 60-150`. Your trained maximum decides where the training steps go.
  Each step is a to-do list in order: "Get 7 x Light Hide" (what to buy or gather, with the cost),
  a check mark for what you already have (in your bags, or made by an earlier step), "Make 27 x
  Light Leather" for anything you have to make first (with its own materials above it), then the
  craft itself.
  Click a step (or a Make line) to craft it: with your profession window open, it starts
  that many, as the window's Create button would (fewer if you lack materials). Enchants that go on
  an item are one per click.
- Character > Crafting (`/talod crafts`): a log of everything you craft, from any window: "39 x Light
  Armor Kit · Leatherworking 12 -> 45 +33", with when, where, your level, the materials used and
  their estimated value (hover). Repeats of one recipe are one entry. Left: totals per profession
  and recipe (crafts, skill gained) for all time, the last 7 days or today; click a recipe to see
  only its entries. Settings: Character > Skills > Crafting log.
- Fixed: the profession plan did not count materials in the reagent bag (e.g. Salt), so it told
  you to buy them again. It uses the game's own count again (bags, reagent bag and bank).
- Fixed: the Skills tab was empty on WoW Forever ("This client does not give addons the skill
  lines"). It now reads the newer skill list (`C_SkillInfo`): weapon skills, defense, professions
  and secondary skills, as on Classic Era. If a client has no skill list at all, it falls back to
  your professions plus defense and the skill of the weapons you hold (from the character stats).
  Opening a profession window also updates that profession's rank.
- Character > Enhance (`/talod enhance`, or click a slot on the Gear tab): what you can put on each
  piece of gear: enchants, armor kits, shield spikes, counterweights, spurs and scopes (temporary
  stones and oils on request). For each: the effect, the profession and skill it takes (green: you
  can; yellow: your skill is too low), where the recipe is learned and its cost, the tool, every
  reagent with how many you have (bags and bank), and how each reagent is made or found (hover for
  the full tree, e.g. Iron Shield Spike <- Iron Bar <- Mining). Only options that fit the item
  (shield, two-hander, bow / gun, item level, your level) are shown unless you ask for everything.
  Data: 166 enhancements from Wowhead Classic, generated by `tools/gen_enhancements.py`.
  Profession filters above the options (with counts for the slot): click to show / hide a
  profession, right-click for only that one, "Mine" for the professions you have. Remembered.

- Gear snapshots now also keep what is behind the numbers: level, talents, passive spells (talent
  effects, racials and other bonuses), shapeshift form or stance, temporary weapon enchants and the
  buffs that were active. Comparing two snapshots shows these side by side and warns when they
  differ ("Different conditions: Talents 3/0/0 vs 2/0/0, Buffs differ"). Talent changes and new
  passive spells get their own ledger entries with what changed and the measured stat difference;
  gear changes say when talents, form, weapon enchants, buffs or level changed at the same time.
  `/talod probe` reports which talent APIs this client has and lists anything it calls "legacy".
- Fixed: a level-up from a kill (or any gear or talent change in combat) saved a snapshot with almost
  no stats, because WoW Forever hides your own stats from addons in combat, and the "before" state
  was overwritten with those hidden values. Changes made in combat are now queued and measured as
  soon as combat ends; "before" is only refreshed out of combat. A snapshot that was saved with
  hidden stats is marked "stats hidden" and filled in automatically the next time your stats can be
  read at the same level in the same gear; its ledger entry is recomputed.
- Character > Progress opens on an overview of every stat: one tile each with the value now, the
  change since your first snapshot, the share from gear and a trend line, grouped like the character
  sheet. Click a tile for its chart. Lists in the character window no longer show a single row when
  the window is opened before the game has sized it.
- Character > Progress chart: pick a stat from a list (with its current value and change since your
  first snapshot) instead of cycling a button; a line chart of every snapshot (or one point per
  level), with a second line for the part that comes from gear; markers under each point (G gear,
  L level, T talents, M manual); hover anywhere for a crosshair on the nearest snapshot and what
  changed there. The character and settings windows are fully opaque.
- The probe and error-log window (`/talod probe`, `/talod errors`) uses the same style.
- Settings have their own window in the same style (`/talod`, the panel's settings button, or
  Options > AddOns > TALOD, which now opens it): sections on the left, sub-tabs on top, flat
  checkboxes, sliders and buttons. It also opens in combat. All settings are unchanged.
- One look across the addon: the Enemies nearby panel, the PvP flag indicator and the character
  window share flat panels, buttons, tabs and list rows. The panel gets striped rows, framed class
  icons, a colored edge for kill-on-sight / avoid / vanished / hidden-hostility rows, a footer line,
  and title-bar buttons for settings, the character window and the lock (unlocked = orange border).
- Character window (`/talod char`): the gear window grew into one window for your character, with a
  Skills tab next to Gear, Ledger, Progress and Sources. Settings: one "Character" tab with Gear and
  Skills pages.
- Skills tracking (`/talod skills`): professions, secondary skills, weapon skills and defense. Each
  skill-up is logged with date, zone and your level (merged while you keep raising one skill in one
  zone), plus training, new skills and dropped ones. Shows rank bars, points gained in the last 7
  days and each skill's history. Collapsed categories in your Skills tab are not read (expand them to
  track those skills).

- Gear ledger (`/talod gear`, new Gear tab): snapshots of everything you wear and your character stats,
  taken when your gear changes, on level-up and when you ask (with a name like "PvP set"). The ledger
  shows each change with what it did: your stats measured right before and after, and the items'
  tooltip stats; a buff that changed during the swap is flagged. Level-ups get their own entries,
  so gear and leveling stay apart. New gear is noted with where it came from (loot, quest reward,
  vendor with the price, mail, trade, crafting, auction house). The window has four views:
  Snapshots (what you wore, compared with any other snapshot), Ledger, Progress (one stat by level,
  with how much came from gear) and Sources. Per character; alts are kept.

- Census: logs every player you see, enemies and allies, for heat maps of where players of each
  class, level and faction travel. A point is where *you* stood when you saw them (within nameplate
  range) plus their distance bracket, class, race, level, guild and the time; party members are
  logged at their own position. Recent points are capped (30 000 by default, about 2–3 MB) and a
  compact all-time summary is kept forever. Allies in capital cities are only counted. Settings:
  the new Census tab (includes a button for friendly nameplates, needed to see allies); `/talod census`.
- `tools/census_viewer.py` turns your saved data into an HTML page of heat maps with filters for
  faction, enemies or allies, class, level, time of day and date. Data is saved on logout or `/reload`.
- Enemies nearby panel: a second line under each enemy in view with health in hit points, a power
  bar, tags (targeting you, PvP flagged, casting, in combat) and their buffs and debuffs. Big
  cooldowns and crowd control are shown first and highlighted. Hover a row for all of it in words,
  plus honor rank. Settings: General > Panel > Enemy details.
- Fixed: players of your own faction could show up in the Enemies nearby list (as `?`) when the
  game hid whether they were hostile, most often in combat. Your faction, your group and friendly
  players are now filtered out, and anyone already listed is dropped as soon as they read as
  allies. Duel opponents and players in free-for-all areas (Gurubashi Arena) are still listed.

### Under the hood: version tracking

- The version now goes up with every update. `version.json` keeps the version and its history;
  `python tools/version.py bump` writes it to the TOC (what the game shows) and stamps this changelog.
  `tests/run.py` and the release build fail when they disagree.

## 0.1.0 — first build (untested in game)

New addon: restart World of Warcraft (not just `/reload`) the first time you install it.

- Enemy spotted alerts (nameplate, target, mouseover), loud for KoS, chosen classes, skulls and
  higher levels.
- Enemies nearby panel with distance brackets, threat sorting, hover details and click to target.
- Nameplate badges and a target readout with your key spells in range.
- Hardcore safety: PvP flag indicator, "this would flag you" target warnings, contested-zone banner.
- Journal: sightings, kill-on-sight and avoid lists, notes, outcomes.
- Optional vanished-stealther alert.
- `/talod probe` reports what your client lets addons read about enemy players.
