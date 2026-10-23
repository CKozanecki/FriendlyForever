# Changelog

### Unreleased

- Fix: Party Hello could say "Hello again" to a group you'd never been in. When the group leader couldn't be read, every such group counted as the same one, so a new group got "Nice to see you all again!", or no hello at all if it came within 30 seconds. The hello type is now chosen when the hello is sent, after the delay, when the leader is more likely to be readable. If the leader still can't be read, the group gets a plain hello and isn't remembered for Hello Again.
- Fix: Party Join no longer welcomes players who join a battleground. Each joiner got their own line in battleground chat, from every addon user. Party Hello also checks the zone now, in case the game doesn't mark a battleground group as one, and both check again just before sending, in case the zone changes during the delay.
- Party Join welcomes players who join close together in one line, such as "Welcome to the group, Ann, Bob and Cid!", instead of a line each. In a party, that's everyone who joins within 3 seconds of the first one, so a single joiner is welcomed a second later than before. In a raid it's 5 seconds. `{name}` and `{fullname}` list everyone in the line, so your own messages work unchanged. After five names the rest are counted ("Ann, Bob, Cid, Dot, Eve and 7 others"), so a long list can't cut off the end of the line. Each player keeps their own repeat cooldown, and anyone who leaves before the line is sent is left out. Party members aren't welcomed again when the party becomes a raid.
- Fix: a forming raid flooded raid chat with a welcome line for every joiner, sent by every addon user in the raid. In a raid, only the raid leader now welcomes joiners, and at most one welcome line goes out every 30 seconds. Anyone who joins in between is added to the next line, so everyone is still welcomed.
- Fix: a Party Hello that was never sent (you left the group or entered a battleground first) no longer turns your next hello to that group into "Hello again".

## 1.5.0

- 30 messages per type (was 10), with 20 new default lines for each. Your current 10 are kept as they are; the new lines fill slots 11–30.
- Better variety: lines are used in a shuffled rotation, so every line comes up once before any repeats (before, a 10-line list repeated often). A new round never starts with the line that ended the last one, and the rotation is saved, so it carries on across reloads and logins. Blanking a line takes it out of the rotation straight away.
- Guild login greetings rewritten with more humour and less cheese ("{name} has logged in. Quick, everyone look busy."). Saved lines still matching the old defaults are swapped for the new ones; lines you edited are kept.

## 1.4.2

- Fix: after a disconnect, buffs you already had (for example Mark of the Wild and Blessing of Might) were thanked in /say as if just cast. The loading screen hung for longer than the 10-second login grace period, so the re-sent buffs looked new. A buff is now skipped when its timer shows it was cast more than 5 seconds ago, however long loading takes. Buffs whose timing the game hides are handled as before.

## 1.4.1

- Fix: Party Hello was skipped for a second group joined within 3 minutes, because one cooldown covered every group. Groups are now told apart by their leader, so a new group always gets its hello. The repeat cooldown only stops a rapid leave and rejoin of the same group (30 seconds, per leader). Saved settings still on 1.4.0's 180 seconds are lowered to 30.
- New **Hello Again** message: rejoining a group you already said hello to this session (same leader) gets a line like "Nice to see you all again!" instead. If it's switched off, the normal hello is used.

## 1.4.0

- New **Party Hello** message: when you join someone else's group, the addon says hello in party (or raid) chat. Before, joining a group sent nothing, because the party welcome only greets people who join after you. It isn't sent when the group forms because someone accepted *your* invite (the party welcome covers that), in battlegrounds, after a reload while already grouped, or if you've left before the delay runs out. It has its own tab with an on/off switch, delay (3s), repeat cooldown and 10 messages.
- The options tabs are a little narrower so five fit across.

## 1.3.4

- Fix: party welcomes were dropped as if the newcomer had already left. The "still in the group?" check asked the game about the name ("Sorum-Md"), a form the game doesn't accept there. It now walks your actual group slots and compares the names the game reports.
- Diagnostics: a dropped message now logs the exact reason (for example "Sorum-Md is no longer in your group").
- Tests: the simulated client only answers group checks for unit slots, like the real one.

## 1.3.3

- Fix: the delay, repeat and "friend" boxes held their values but showed blank until clicked. Setting a box's text moves its cursor to the end, which can scroll a narrow box's text out of view. Every box now shows its text from the start.

## 1.3.2

- Fix (safeguard): the delay and repeat boxes in the options panel could sometimes show empty, although the saved values were fine. The panel is now filled when it's created, when it's shown, and again on the next frame, after the settings window has finished laying out.
- Diagnostics: with debug on, every panel fill is logged with the saved values and what each box actually shows.

## 1.3.1

- Fix: a Lua error in combat ("attempt to perform boolean test on field 'isFullUpdate' (a secret boolean value)"). In combat the game makes buff-update fields secret. They are now checked before use, and restricted updates are skipped and counted in `/friendly status`.
- Fix: the "still in the group?" check before a party welcome no longer tests values that can be secret in combat.
- Tests: the simulated client now has a combat mode (secret unit queries) and stricter secret values.

## 1.3.0

- Buff thanks: the buff tab and `/friendly status` warn when friendly player nameplates are off, because without them the game can rarely name who buffed you. A **"Show friendly player names"** button and `/friendly nameplates` turn them on (names only). The addon never changes this setting by itself.
- Buff thanks: new **"If the caster can't be named or whispered, thank them in /say"** setting (on by default). It now also covers whisper mode, and whispers the game can't deliver.
- The options page scrolls, so no row is cut off on small screens.
- Settings from 1.2.x with a blank unknown-caster name (meaning "don't thank them") are migrated to the new setting being off.

## 1.2.2

- Diagnostics: buff thanks skipped for an unidentified caster (whisper mode, or a blank fallback name) now say so in the debug log instead of skipping silently.

## 1.2.1

- Fix: names kept their Forever surname. 1.2.0 and earlier cut "Nikki-Shifts" down to "Nikki", so whispers failed ("No player named 'Nikki' is currently playing"), and the names used for guild roster checks, cooldowns and "is this me" were wrong.
- `{name}` is the first name ("Welcome back, Nikki!"). The new `{fullname}` placeholder gives "Nikki Shifts".
- New `/friendly names` shows exactly how the game reports names.

## 1.2.0

- Diagnostics: `/friendly status`, `/friendly selftest` and `/friendly debug` (decision log saved to disk).
- Send errors from the game are now recorded instead of silently swallowed, and "action blocked" events against the addon are reported.
- Lua errors in event handlers and timers are counted and logged, and still shown by WoW's error display.
- Buff thanks: buff data the event can't show directly is re-read from the game by its ID, and new buffs are found in full aura refreshes too.
- The key-press listener frame now has a size and position.

## 1.1.1

- Buff thanks: the "friend" fallback for unidentified casters is off while you're in a group, so a groupmate's totems, auras or shouts are never thanked as a stranger's. Named strangers are still thanked while grouped.

## 1.1.0

- Buff thanks: several buffs from one person become a single thank-you that lists them all.
- Buff thanks: casters are also found from a matching spell cast. Casters who can't be identified are thanked as "friend" (configurable).
- Buff thanks: new option to whisper the caster instead of using /say (no key press needed).
- Every message type now has a "don't repeat to the same player" setting (default 3 minutes).
- Outgoing chat is sanitised, rate-limited and held during chat lockdown.
- Saved settings are validated on load and migrated from 1.0.
- Automated tests, lint, and a CurseForge-style package build.

## 1.0.0

- First version: guild login and join greetings, party welcomes, buff thanks, options panel, minimap button.
