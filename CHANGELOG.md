# Changelog

### Unreleased

- **Buff receipts:** when your buff lands on a player outside your group, your copy of the addon tells theirs with one hidden addon whisper. When their game can't say who buffed them, their copy can then thank you by name and offer your buff back, rather than thanking "friend". A receipt only names the caster of a matching buff that really arrived a moment before; on its own it never causes a cast, a thank-you or an offer. A buff whose caster can't be named now waits 2 seconds for a receipt before it's thanked as "friend". None are sent to your group, inside instances or during chat lockdown. Switch it off with **Tell players I buff that it was me** on the Buff Thanks tab. (#138)
- Fix: a buff cast by hand on another player in the few seconds the buff back button waits for its own cast is no longer taken as the button's cast. It is remembered as a buff to that player, so their buff back isn't owed again and a favour you owe them is returned, and the button keeps waiting and reports its own answer. If the button's own cast went to someone else, it still says "went to Ann, not Bob" a few seconds later, and that buff counts for Ann too. (#133)
- This version adds files (the new icon, Battleground.lua, Cities.lua, Comm.lua, Exchange.lua, RateLimit.lua and Receipts.lua). After updating, restart the game; /reload isn't enough. (#32, #34, #35, #36, #65, #71, #138)
- **Quiet in capital cities** (on by default): no buff thank-yous in Stormwind, Ironforge, Darnassus, Orgrimmar, Thunder Bluff or Undercity, though the favour ledger still counts them. The buff back button stays hidden there unless you switch **Show the button in capital cities** on, and shows your favours once you leave. Buff mode turned on in a city works as usual; a stranger's buff doesn't turn it on there. (#34)
- The copy window (export, import and the bug report) has room for a hint on two lines, so the import hint no longer runs into the box you paste into. On the **Favour Ledger** page, each row stays on one line, cut with "…" when it's long, so a long row can't push the rest off the page; `/friendly ledger` shows them in full. The **General** page scrolls, so long lists can't push its last settings out of reach, and it lists your first 6 profiles and counts the rest (`/friendly profile` shows them all). (#52)
- Friendly Forever has its own icon, the gold heart from its logo, on the minimap button, in the addon compartment and in the AddOns list. (#65)
- Copies of Friendly Forever can now talk to each other with hidden addon messages, for features to come. No chat channel is ever joined. Every message from another player is checked and rate-limited, and none can make the addon cast, speak or change your settings. `/friendly status` shows what was sent, received and dropped. (#32)
- **Chat limit:** at most 4 lines a minute in each chat (/say, whispers, emotes, guild, group) by default, set from 1 to 10 on the **General** page. It keeps the addon a helper, not a spammer: thank-yous over the limit are dropped and the ledger says why (the first one each session is also mentioned in your own chat window), and greetings wait for room. `/friendly status` counts both. (#35)
- Fix: settings damaged while you play (by another addon or a bad `/run`) no longer cause Lua errors in the ignore list, snooze, profiles or import undo. They are repaired as soon as they're used, and a damaged snooze never lasts more than a day. (#52)
- Fix: after the favour ledger is damaged while you play, its counts stay right. A favour still waiting for its thanks or return is counted again, and the all-time totals never fall below today's. (#52)
- The options tabs take the panel's full width each time it opens, as the **General** page does, so their message boxes and notes are never squeezed into a narrow strip. The **Buff Back** tab's description wraps instead of running off the panel's edge. (#112)
- The buff-back button keeps its text inside it: a name or favour too long for the button is cut off with "…", and the hint while you move it is shorter. On the options tabs, the message lines no longer sit below an empty gap. (#64)
- **Battlegrounds:** before the gates open, buff mode and buff back work as in any raid. Once the battle starts the addon goes quiet until you leave or the battleground ends: buff mode ends and nothing turns it on, the buff back button hides, buffs you get aren't thanked or owed, and no lines are sent (guild hellos still go to guild chat). If the game doesn't say the battle hasn't started, it counts as started. Switch off **Buff in the preparation phase** on the **Buff Back** tab to keep the preparation phase quiet too. (#71)
- **Buff mode:** a group member whose name hasn't loaded yet (shown as "Unknown") is no longer offered a buff. Buff mode stays on and offers it once the name loads. A buff from a player whose name hasn't loaded owes no favour. (#99)
- **Buff back: one round each way.** Buffs you cast by hand are now remembered too, so a stranger's buff back within 10 minutes answers yours and isn't owed. A buff you cast by hand on someone you owe returns their favour. When you return a favour, your copy of the addon tells theirs, so they don't owe you one back even after a longer wait. (#37)
- **Buff exchanges: one thank-you each way, after the last buff.** When you and a stranger trade buffs, your thank-you waits until the exchange is done, so it comes after your own buff back and lists every buff they gave you. It waits at least 2 seconds after the last buff either way, and while the buff back button holds them: up to 5 seconds after the last buff, or, when their copy of the addon is there, until you cast it or let it go (right-click). The two copies tell each other what their buttons hold, so each waits for the other's buff too. A thank-you always goes out within 30 seconds of the first buff it thanks for, and a buff from them later in the same exchange isn't thanked again. An exchange ends 10 seconds after its last buff. (#36)
- Buff thanks no longer raises a Lua error on a buff whose caster the game reports as something other than a unit name. Such a buff isn't thanked or owed. (#98)
- Fix: buff thanks no longer raises a Lua error when the game sends a damaged aura ID (not a number, or NaN). The buff is still thanked as usual. (#108)
- Buff data: the shaman's Water Breathing is listed as doing the same job as a warlock's Unending Breath, not as a group version of it. A player wearing either still counts as having Unending Breath. (#135)
- **Thank them with** and **If that can't reach them** on the Buff Thanks tab replace the whisper and /say fallback checkboxes. Thank with a line in /say (the default), a whisper, a `/thank` emote, or a line and an emote. When that can't reach them (the game can't name the caster, or the whisper fails), say it in /say as "friend" (the default), `/thank` instead, or do nothing. The line once your buff lands goes the same way, as a `/thank` for the emote. The favour ledger notes how each favour was thanked. Your settings carry over: if you thanked with only an emote, a caster the game can't name still gets a plain `/thank`, and a whispered line with an emote becomes just the whisper. (#101)

## 0.8.0

- This version adds files. After updating, restart the game; /reload isn't enough. (#27, #52)
- Version numbers now count up from 0: this is 0.8.0, the first file on CurseForge, and 1.0.0 will be the launch. The options button that loads the old default lines now reads **Load casual lines (0.6)**. (#80)
- **Buff back:** when someone outside your group buffs you, a button offers your buff back. Press it, or its key in Key Bindings > AddOns, to cast it on them; your own target comes back afterwards. It picks a buff they don't already have and can use, waits while they're dead, and won't flag you for PvP: it reads their flag as you press, so it's offered only while the game shows them (friendly nameplates help). Right-click lets a favour go. `/friendly move` moves the button and `/friendly buffback` shows what it holds. Untested in WoW Forever until launch. (#27)
- Settings damaged while you play (by another addon or a bad `/run`) are repaired as soon as they cause an error, not at the next reload. (#27)
- New **Buff Back** tab: offer on or off, how long favours are offered, and an optional line to say once your buff lands (30 editable lines, off by default). (#27, #57)
- **Buff mode:** lend the buff back button a key while it's on, the mouse wheel by default, and give the key back when it ends. Switch it with `/friendly buffmode` or its own key binding; choose the key on the **Buff Back** tab. (#28)
- In buff mode, the button also buffs party and raid members missing your buffs, one per press, with the same safety rules as buff back. (#30)
- Buff mode can turn itself on (when you join a group, after a death in your group, or when someone outside your group buffs you; each on by default, and switchable on the **Buff Back** tab) and off again (at the first pull, once everyone has your buffs, or after a timeout). (#29)
- On the **Buff Back** tab, put your class's buffs in the order you want them offered, and mark any **Never offer**. (#31)
- In buff mode, choose who gets each buff: everyone, tanks only (read from the group's roles and the raid's Main Tank), everyone but tanks, or chosen classes, plus players who always or never get it. Salvation isn't a Blessing on WoW Forever, so it's given beside your Blessing, and it goes to everyone but tanks by default. (#68)
- Paladins: buff mode offers **Revoke** on members wearing Salvation they shouldn't have (by default, your own Salvation on members your rules keep it off; or any tank, chosen tanks, chosen players), before new buffs. (#68)
- Paladins: choose **My Blessings in this raid**, so two paladins don't both give Kings: tick them on the **Buff Back** tab or use `/friendly blessings might wisdom`. Not saved; forgotten when you leave the raid. (#68)
- In buff mode, Shift+right-click on a group buff puts that member on the buff's **Never** list. Right-click still skips them for 5 minutes. (#68)
- The favour ledger counts favours you returned and gives titles for them, from Courteous at 10 to Friend to All Azeroth at 1,000. (#27)
- New default lines for every message type, in a Warcraft fantasy voice. Saved lines still on the old defaults are switched to the new ones; lines you edited are kept. The old lines are still there: each tab's **Load casual lines (0.6)** button puts them back. (#52)
- Flavour placeholders change with the moment: `{greeting}`, `{thanks}`, `{blessing}` and `{cheer}` follow your race, faction, where you are and the hour ("Throm-ka, Thrall! Strength and honor."), and `{zone}`, `{timeofday}`, `{myclass}` and `{class}` (theirs, when the game says) fill in the details. Use them in your own lines too. Every Forever race has its own voice, including separate ones for the High Order and Windshaper Skyborne. (#52)
- Favour ledger: who buffed you, with what, and whether you thanked them, or why not. Today's count and all-time totals, on the new **Favour Ledger** options page or with `/friendly ledger`. (#52)
- Buff Thanks can `/thank` the caster instead of, or as well as, saying a line (**How to thank** on the Buff Thanks tab). (#52)
- Ignore list: `/friendly ignore <name>` (or your target) means that player is never greeted, welcomed or thanked. (#52)
- `/friendly snooze [minutes]`: send nothing for a while (15 minutes by default). (#52)
- Profiles: `/friendly profile new | use | delete <name>`. Each character switches to the profile it used last when it logs in. (#52)
- `/friendly export` and `/friendly import`: your settings as one line of text, to keep or share. Importing never turns the addon on or off and only adds to your ignore list. `/friendly import undo` puts your settings back. (#52)
- `/friendly report` and **Copy for a bug report**: the status and debug log as text to copy. (#52)
- New **General** options page with all of the above as buttons. Friendly Forever is also in the addon compartment (the addon drop-down by the minimap) where the game has one, and the minimap tooltip shows snooze and today's favours. (#52)

## 0.6.0

- This version adds a file (Defaults.lua, which now holds the default messages). After updating, restart the game; /reload isn't enough. Messages and settings are unchanged.
- Fix: a forming raid flooded raid chat with a welcome line for every joiner, sent by every addon user in the raid. In a raid, only the raid leader now welcomes joiners, and at most one welcome line goes out every 30 seconds. Anyone who joins in between is added to the next line, so everyone is still welcomed.
- Party Join welcomes players who join close together in one line, such as "Welcome to the group, Ann, Bob and Cid!", instead of a line each. In a party, that's everyone who joins within 3 seconds of the first one, so a single joiner is welcomed a second later than before. In a raid it's 5 seconds. `{name}` and `{fullname}` list everyone in the line, so your own messages work unchanged. After five names the rest are counted ("Ann, Bob, Cid, Dot, Eve and 7 others"), so a long list can't cut off the end of the line. Each player keeps their own repeat cooldown, and anyone who leaves before the line is sent is left out. Party members aren't welcomed again when the party becomes a raid.
- Fix: Party Join no longer welcomes players who join a battleground. Each joiner got their own line in battleground chat, from every addon user. Party Hello also checks the zone now, in case the game doesn't mark a battleground group as one, and both check again just before sending, in case the zone changes during the delay.
- Fix: Party Hello could say "Hello again" to a group you'd never been in. When the group leader couldn't be read, every such group counted as the same one, so a new group got "Nice to see you all again!", or no hello at all if it came within 30 seconds. The hello type is now chosen when the hello is sent, after the delay, when the leader is more likely to be readable. If the leader still can't be read, the group gets a plain hello and isn't remembered for Hello Again.
- Fix: a Party Hello that was never sent (you left the group or entered a battleground first) no longer turns your next hello to that group into "Hello again".
- New option **Don't send messages while I'm AFK** (on by default): greetings and buff thanks that come due while you're AFK are dropped instead of sent. A /say thank-you waiting for a key press still goes out if that key press brings you back. `/friendly test` and `/friendly selftest` aren't affected. `/friendly status` shows whether it's on, whether you're AFK, and when messages are being dropped because of it.
- Fix: guild login greetings were missed when a guild roster update arrived before the refreshed roster (common with "Show Offline Members" off, or when other addons or the guild frame ask for the roster). A login waiting for the roster now stays waiting until the roster confirms it or 30 seconds pass; friends outside the guild are still never greeted.
- Fix: a buff from someone the game can't name could be credited to another player who had just cast the same spell on someone else (for example, mages buffing in a city). A cast now only names its caster when it was aimed at you. A cast aimed at someone else, or one where the game won't say who it was aimed at, is ignored. Out in the world, a buff whose caster can't be identified still gets the "friend" thank-you in /say (if that is switched on). In a group or battleground it is skipped, as before.
- Fix: a /say thank-you waiting for a key press could go out up to 2 minutes late, after the buffer had moved on. It's now dropped if it waits more than 30 seconds, counted from when it's ready to send (after the configured delay). Whispers and other messages still wait up to 2 minutes.
- Fix: `/friendly test` and the options panel's **Preview random** used up lines from the message rotation, so previewed lines were then skipped when sending for real. Previews now pick a line without touching the saved rotation.
- Fix: typing in an options box could be undone, with the cursor jumping to the start, whenever a game setting changed (for example through a keybind or another addon). The panel is no longer refilled while it's closed, and the box you're typing in is left alone. Switching tabs or resetting a tab finishes your edit first.
- Faster in busy places: Friendly Forever only listens for other players' spellcasts while Buff Thanks is on, rejects casts from your group and other units it never thanks before doing any work, and no longer makes new tables for every event it handles. Nothing it sends changes.
- README: say thanks waiting for a key press aren't sent while the interface is hidden (Alt+Z).
- Note: going back to a 0.4.x version keeps only the first 10 lines of each message type, so if you then upgrade again, lines 11 to 30 are back to the defaults.

## 0.5.0

- 30 messages per type (was 10), with 20 new default lines for each. Your current 10 are kept as they are; the new lines fill slots 11–30.
- Better variety: lines are used in a shuffled rotation, so every line comes up once before any repeats (before, a 10-line list repeated often). A new round never starts with the line that ended the last one, and the rotation is saved, so it carries on across reloads and logins. Blanking a line takes it out of the rotation straight away.
- Guild login greetings rewritten with more humour and less cheese ("{name} has logged in. Quick, everyone look busy."). Saved lines still matching the old defaults are swapped for the new ones; lines you edited are kept.

## 0.4.2

- Fix: after a disconnect, buffs you already had (for example Mark of the Wild and Blessing of Might) were thanked in /say as if just cast. The loading screen hung for longer than the 10-second login grace period, so the re-sent buffs looked new. A buff is now skipped when its timer shows it was cast more than 5 seconds ago, however long loading takes. Buffs whose timing the game hides are handled as before.

## 0.4.1

- Fix: Party Hello was skipped for a second group joined within 3 minutes, because one cooldown covered every group. Groups are now told apart by their leader, so a new group always gets its hello. The repeat cooldown only stops a rapid leave and rejoin of the same group (30 seconds, per leader). Saved settings still on 0.4.0's 180 seconds are lowered to 30.
- New **Hello Again** message: rejoining a group you already said hello to this session (same leader) gets a line like "Nice to see you all again!" instead. If it's switched off, the normal hello is used.

## 0.4.0

- New **Party Hello** message: when you join someone else's group, the addon says hello in party (or raid) chat. Before, joining a group sent nothing, because the party welcome only greets people who join after you. It isn't sent when the group forms because someone accepted *your* invite (the party welcome covers that), in battlegrounds, after a reload while already grouped, or if you've left before the delay runs out. It has its own tab with an on/off switch, delay (3s), repeat cooldown and 10 messages.
- The options tabs are a little narrower so five fit across.

## 0.3.4

- Fix: party welcomes were dropped as if the newcomer had already left. The "still in the group?" check asked the game about the name ("Sorum-Md"), a form the game doesn't accept there. It now walks your actual group slots and compares the names the game reports.
- Diagnostics: a dropped message now logs the exact reason (for example "Sorum-Md is no longer in your group").
- Tests: the simulated client only answers group checks for unit slots, like the real one.

## 0.3.3

- Fix: the delay, repeat and "friend" boxes held their values but showed blank until clicked. Setting a box's text moves its cursor to the end, which can scroll a narrow box's text out of view. Every box now shows its text from the start.

## 0.3.2

- Fix (safeguard): the delay and repeat boxes in the options panel could sometimes show empty, although the saved values were fine. The panel is now filled when it's created, when it's shown, and again on the next frame, after the settings window has finished laying out.
- Diagnostics: with debug on, every panel fill is logged with the saved values and what each box actually shows.

## 0.3.1

- Fix: a Lua error in combat ("attempt to perform boolean test on field 'isFullUpdate' (a secret boolean value)"). In combat the game makes buff-update fields secret. They are now checked before use, and restricted updates are skipped and counted in `/friendly status`.
- Fix: the "still in the group?" check before a party welcome no longer tests values that can be secret in combat.
- Tests: the simulated client now has a combat mode (secret unit queries) and stricter secret values.

## 0.3.0

- Buff thanks: the buff tab and `/friendly status` warn when friendly player nameplates are off, because without them the game can rarely name who buffed you. A **"Show friendly player names"** button and `/friendly nameplates` turn them on (names only). The addon never changes this setting by itself.
- Buff thanks: new **"If the caster can't be named or whispered, thank them in /say"** setting (on by default). It now also covers whisper mode, and whispers the game can't deliver.
- The options page scrolls, so no row is cut off on small screens.
- Settings from 0.2.x with a blank unknown-caster name (meaning "don't thank them") are migrated to the new setting being off.

## 0.2.2

- Diagnostics: buff thanks skipped for an unidentified caster (whisper mode, or a blank fallback name) now say so in the debug log instead of skipping silently.

## 0.2.1

- Fix: names kept their Forever surname. 0.2.0 and earlier cut "Nikki-Shifts" down to "Nikki", so whispers failed ("No player named 'Nikki' is currently playing"), and the names used for guild roster checks, cooldowns and "is this me" were wrong.
- `{name}` is the first name ("Welcome back, Nikki!"). The new `{fullname}` placeholder gives "Nikki Shifts".
- New `/friendly names` shows exactly how the game reports names.

## 0.2.0

- Diagnostics: `/friendly status`, `/friendly selftest` and `/friendly debug` (decision log saved to disk).
- Send errors from the game are now recorded instead of silently swallowed, and "action blocked" events against the addon are reported.
- Lua errors in event handlers and timers are counted and logged, and still shown by WoW's error display.
- Buff thanks: buff data the event can't show directly is re-read from the game by its ID, and new buffs are found in full aura refreshes too.
- The key-press listener frame now has a size and position.

## 0.1.1

- Buff thanks: the "friend" fallback for unidentified casters is off while you're in a group, so a groupmate's totems, auras or shouts are never thanked as a stranger's. Named strangers are still thanked while grouped.

## 0.1.0

- Buff thanks: several buffs from one person become a single thank-you that lists them all.
- Buff thanks: casters are also found from a matching spell cast. Casters who can't be identified are thanked as "friend" (configurable).
- Buff thanks: new option to whisper the caster instead of using /say (no key press needed).
- Every message type now has a "don't repeat to the same player" setting (default 3 minutes).
- Outgoing chat is sanitised, rate-limited and held during chat lockdown.
- Saved settings are validated on load and migrated from 0.0.
- Automated tests, lint, and a CurseForge-style package build.

## 0.0.0

- First version: guild login and join greetings, party welcomes, buff thanks, options panel, minimap button.
