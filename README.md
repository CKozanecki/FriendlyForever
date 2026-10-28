# Friendly Forever

A courtesy addon for **World of Warcraft: Forever** (TOC interface `16001`).

- **Greetings and thanks:** greets guildmates who log in, welcomes new guild and group members, says hello when you join a group, and thanks players outside your group who buff you, in chat messages you can edit (below).
- **Buff back:** when a stranger buffs you, a button offers your buff back, cast with one press ([Buff back](#buff-back)).
- **Favour ledger:** who buffed you, whether you thanked them, and favours you returned, with titles for returning them ([Favour ledger](#favour-ledger)).
- **Flavour:** the default lines speak in your race's voice and change with where you are and the hour ([Flavour](#flavour)).
- **Control:** an ignore list, snooze, profiles, and export or import of your settings ([Use](#use)).

The chat messages:

| Event | Sent to | Placeholders |
|---|---|---|
| Guild member logs in | Guild chat | `{name}`, `{fullname}` |
| A player outside your group buffs you | Say, or a whisper to them | `{name}`, `{fullname}`, `{buff}` |
| New member joins the guild | Guild chat | `{name}`, `{fullname}` |
| Player joins your group (not in battlegrounds; joins a few seconds apart share one line, which lists them all; in a raid, only the leader welcomes, at most once every 30 seconds) | Party or raid chat | `{name}`, `{fullname}` |
| You join someone else's group | Party or raid chat | none |
| You rejoin a group (same leader) this session | Party or raid chat | none |
| Your buff from the buff back button reaches them, with its line switched on (off by default) | Say | `{name}`, `{fullname}`, `{buff}` |

`{name}` is the first name ("Nikki") and `{fullname}` the whole name ("Nikki Shifts"). Forever characters always have a surname. The addon identifies players by their full name, so two people called Nikki are never mixed up.

Each message type except Buff Back has its own on/off switch, a delay, a "don't repeat to the same player" cooldown (default 3 minutes; for the two hellos it's per group leader and 30 seconds) and 30 editable messages. Buff Back's line has its own switch and 30 lines but no delay or cooldown: it's said once for each favour you return. Lines are used in a shuffled rotation: every line comes up once before any repeats, a new round never starts with the line that just ended the last one, and the rotation carries over across reloads and logins.

## Flavour

The default lines are written in a Warcraft fantasy voice, and some words in them change with the moment:

| Placeholder | Becomes |
|---|---|
| `{greeting}` | A greeting in your race's voice: "Well met", "Throm-ka", "Ishnu-alah", "Good to see ye"… |
| `{thanks}` | A thank-you in your race's voice: "Thank ye kindly", "My thanks"… |
| `{blessing}` | A parting wish chosen by your race, faction, where you are and the hour: "Elune light your path.", "Safe travels through Westfall.", "Rest well tonight." |
| `{cheer}` | A rallying cry: "For the Horde!", "For Khaz Modan!" |
| `{zone}` | Where you are ("Elwynn Forest"; "these lands" if the game doesn't say) |
| `{timeofday}` | "morning", "afternoon" or "evening", by the game's clock |
| `{myclass}` | Your class ("mage") |
| `{class}` | Their class, when the game says (a guildmate from the roster, or whoever buffed you); otherwise "friend" |

Every Forever race has its own voice: the eight original races, and both Skyborne peoples. The High Order (Alliance) speaks of ley lines and Eldre'Thalas, the Windshapers (Horde) of the winds and the sky spirits. They share one race name in the game, so the addon tells them apart by race ID, or by faction. `/friendly status` shows how the game reports your race and whose voice you're using.

So "{greeting}, {name}! {blessing}" comes out as "Throm-ka, Thrall! Strength and honor." from an orc, or "Ishnu-alah, Thrall! Elune light your path." from a night elf. The same words aren't used again until a few others have been. Use these in your own lines too.

The 1.5 to 1.6 default lines are still there: each tab's **Load casual lines (1.6)** button puts them back, and **Load fantasy lines** loads the new ones. Lines you edited are never replaced by an update.

## Install

With the CurseForge app, search for **Friendly Forever** and install it for WoW Forever.

By hand: unzip `FriendlyForever-<version>.zip` (or copy the `FriendlyForever` folder) into the AddOns folder of your WoW Forever game folder:

```
<your WoW Forever game folder>/Interface/AddOns/
```

To find the game folder, open the Battle.net app, choose WoW Forever, then the gear next to Play and **Show in Explorer** (**Show in Finder** on a Mac). Beta testers' copies were in `World of Warcraft/_classic_beta_/`.

## Use

- **Options:** Esc → Options → AddOns → Friendly Forever, or type `/friendly`. A tab per message type (including **Buff Back**), plus the **General** page (snooze, ignore list, profiles, export and import, bug report) and the **Favour Ledger** page.
- **Minimap button:** left-click opens options, right-click turns the addon on or off, drag to move it. Friendly Forever is also in the addon compartment (the addon drop-down by the minimap) where the game has one.
- **Key binding:** Key Bindings → AddOns → "Friendly Forever: buff back" presses the buff back button.
- `/friendly on | off | toggle`: turn everything on or off. `/friendly help` lists every command (`/ffr` also works).
- `/friendly test`: preview one message of each type (only you see it). `/friendly say`: send a waiting buff thank-you now. `/friendly minimap`: show or hide the minimap button.
- `/friendly snooze [minutes] | off`: send nothing for a while (15 minutes by default, up to a day). It holds across a reload.
- `/friendly ignore [name]` and `/friendly unignore <name>`: never greet, welcome or thank a player. Use the full name ("Nikki Shifts"); with no name it takes your target, or lists the names when you have no target.
- `/friendly ledger [count] | clear`: the favour ledger (see below).
- `/friendly profile [new | use | delete] <name>`: profiles. Each character switches to the profile it used last when it logs in.
- `/friendly export` and `/friendly import [undo]`: your settings as one line of text, to keep or share. Importing never turns the addon on or off and only adds to your ignore list; `import undo` puts your settings back.
- The **General** page has buttons for snooze, the ignore list, profiles, export and import, and the bug report; the **Favour Ledger** page shows the ledger.
- Buff back: `/friendly buffback` (what the button holds), `/friendly move` (drag it) and `/friendly buffmode` (lend it a key). See [Buff back](#buff-back).
- Checking what the addon does: `/friendly status`, `/friendly selftest`, `/friendly names`, `/friendly nameplates`, `/friendly debug` and `/friendly report`. See [Troubleshooting](#troubleshooting).
- **Don't send messages while I'm AFK** (on by default, at the top of the options): a greeting or thank-you that comes due while you're AFK is dropped, not saved for later. `/friendly test` and `/friendly selftest` still work.

## Troubleshooting

- `/friendly report` (or **Copy for a bug report** on the General page) shows the status and the debug log as text to copy into a bug report.
- `/friendly status` shows whether the addon is active, the login grace period, guild roster size, chat lockdown, what it has seen and sent, send errors, calls the game blocked, and Lua errors.
- `/friendly selftest` whispers you through the real send path, to prove sending works.
- `/friendly nameplates` turns on friendly player names, which the game needs to name casters.
- `/friendly names` shows exactly how the game reports your name, your target's and the guild roster's, and the name the addon uses.
- `/friendly debug` logs every decision with its reason, both to chat and to `WTF/Account/<account>/SavedVariables/FriendlyForever.lua`. That file is written on `/reload` or logout. Turn debug off again with the same command.
- `/console scriptErrors 1` makes WoW show Lua errors. They are hidden by default.

## Buff thanks

No combat log is used. New buffs come from `UNIT_AURA`, and the caster is identified, in order, by:

1. The aura's caster unit (target, mouseover, focus, nameplate, and so on).
2. A matching spell cast seen from one of those units just before the buff landed.
3. Otherwise the caster is **unidentified**.

**Turn on friendly player nameplates.** The game can only name a caster it has a unit for. Without friendly player nameplates, most strangers who buff you can't be named. The buff tab warns you when they're off, and its **"Show friendly player names"** button (or `/friendly nameplates`) turns them on as names only. The addon never changes this setting by itself.

**Say or whisper.** The game only allows addons to use `/say` outdoors right after a key press. Say thanks therefore wait and go out on your next key press, or when you type `/friendly say`. Turn on **"Whisper the caster instead of /say"** to whisper them immediately instead. While the interface is hidden (Alt+Z), key presses don't send waiting say thanks. Show it again and they go out on your next key press, unless they've waited longer than 2 minutes.

**The "friend" fallback** (on by default) thanks in `/say` as **"friend"** (wording configurable) when:
- the caster is unidentified, in either mode, or
- the game can't deliver the whisper ("No player named … is currently playing").

It's off while you're in a group, because party-wide buffs such as a groupmate's totems, auras or shouts can arrive with no caster, and must never be mistaken for a stranger's. Strangers the game can name are still thanked while you're grouped.

Buffs from one person that arrive before the thank-you goes out are combined: *"Thank you for the Power Word: Fortitude and Divine Spirit, Bob!"*. The repeat cooldown then stops any second thank-you.

**How to thank** (on the Buff Thanks tab): a line in /say or a whisper (the default), a `/thank` emote, or both. The emote is aimed at the caster while the game still has them on a nameplate or as your target, and is a plain `/thank` otherwise. It waits for a key press, like /say. Whether the game requires that for emotes hasn't been tested yet, so the addon plays it safe.

## Buff back

When someone outside your group buffs you, a small button appears with their name and the buff you can give back. Press it, or the key you set for it in **Key Bindings → AddOns** ("Friendly Forever: buff back", with or without Shift/Ctrl/Alt), and it casts your buff on them and gives you your own target back. The game only lets an addon cast through a button you press, so nothing is ever cast without your key press or click.

- **Which buff:** your class's buffs that you know, in your order. On the **Buff Back** tab you can move each buff up or down and mark any of them **Never offer**; the order and marks go with your profile and export, and each class keeps its own. It skips any they already wear (when the game lets the addon see), mana buffs for classes without mana, and buffs that only reach your own party. A druid gives Mark of the Wild, or Thorns to someone who already has the Mark.
- **Who:** the newest favour first. It waits while they're dead. It never offers a buff to someone the game shows flagged for PvP unless you're flagged too, since buffing them would flag you. Their flag is read again at the moment you press, so unless you're flagged, a favour is offered only while the game shows them (on a nameplate, as your target or under your mouse). If it can't see them, the button says so; target them, or turn on friendly nameplates. Favours are dropped after 10 minutes (adjustable on the **Buff Back** tab), and are forgotten on a reload or logout.
- **No endless trading:** when another player answers your buff with one of theirs, that isn't a new favour (for 10 minutes).
- **Right-click** the button to let a favour go.
- **Feedback:** what each press did, under the button (and in chat where it needs your attention):
  - returned: "Returned Mark of the Wild to Bob Stone.";
  - the game doesn't say who it reached: "Cast Mark of the Wild, but the game didn't say it reached Bob Stone." The favour isn't counted as returned;
  - it went to someone else: "Mark of the Wild went to Ann Vale, not Bob Stone." in chat, and the favour stays;
  - the game refuses it: its reason in chat ("Couldn't buff Bob Stone: Out of range."), or "Couldn't buff Bob Stone (the game gave no reason).", and the favour stays;
  - nothing was cast: "No answer: couldn't find Bob Stone (out of sight?)." in chat;
  - the server never answers (a lag spike): "No word back on Mark of the Wild for Bob Stone. If it didn't land, press again.";
  - the favour had already gone (it expired, or you let it go) by the time the cast landed: "Cast Mark of the Wild on Bob Stone (no favour was waiting).";
  - right-click: "Let Bob Stone go."

  Pressing again while a cast is still on its way is fine: each answer is matched to its own press where the game says which, and otherwise to the newest.
- **After a /reload in a fight** the button appears when the fight ends.
- **Say a line once the buff lands** (off by default, on the **Buff Back** tab): 30 editable lines, with the flavour placeholders and `{buff}`. The line is said only after the game confirms your buff reached them, never for a cast that failed, went to someone else or found nobody. Like a thank-you, it goes out on your next key press (the game only lets /say follow one) and is dropped if that takes more than 30 seconds.
- **In combat** the button is empty: it clears itself as a fight starts and fills again afterwards. The game locks secure buttons in fights, so whatever it held would otherwise stay on it, aimed at the world outside the fight.
- **Say a line** only while the addon may speak: not while snoozed, or AFK with "Don't send messages while I'm AFK" on.
- `/friendly move` unlocks the button so you can drag it, and locks it again. `/friendly buffback` shows exactly what the button holds and why, for checking in game.

### Buff mode

Buff mode lends the button a key of your choice while it's on, the mouse wheel by default, so you can buff quickly by scrolling. When buff mode ends, the key does what it did before. It never casts by itself: each cast still needs your press, the key only decides which press.

- **On and off:** `/friendly buffmode` switches it, `/friendly buffmode on` or `off` sets it, and **Key Bindings → AddOns → "Friendly Forever: buff mode on/off"** gives it a key. It needs the addon and Buff Back on, and it's off after a login or reload.
- **The key:** on the **Buff Back** tab, click **Buff mode key** and press a key, scroll the wheel or click a side mouse button (Esc cancels), with Shift, Ctrl or Alt if you like. Or type `/friendly buffmode key MOUSEWHEELDOWN`. Esc, Enter, `/`, and the left and right mouse buttons can't be lent, nor the key that switches buff mode. A fight starting cancels the wait for a key. A key that can't be used, or that the game won't lend, falls back to Mouse Wheel Up, with a message.
- **Your group:** in buff mode the button also offers your buffs to party or raid members missing them, one per press, after any favours you owe. Your first buff goes to everyone missing it before your second goes to anyone, in your buff order, skipping buffs their class can't use and buffs you cast on yourself (Battle Shout). It uses the same safety rules as buff back: it skips anyone dead, offline, out of your spell's range or too far away for the game to show, and anyone flagged for PvP unless you're flagged too (read as you press). A member whose name, flag or buffs can't be read is skipped, and the button says why. The game can't tell an addon about line of sight, so if it refuses a cast (out of sight, say), that member waits 15 seconds and the next press goes to the next member. A paladin gives each member one Blessing (in your buff order) and never casts another over it, since that would replace it. Group buffs never say a line and aren't thanked or counted as favours. "Gave Mark of the Wild to Ann Vale." shows under the button; right-click skips that member for 5 minutes.
- **Who gets each buff** (Buff Back tab): each buff's **Who** button steps through *Everyone*, *Tanks only*, *Everyone but tanks* and *Chosen classes* (tick the classes below the list). Below it, name players who **Always** or **Never** get that buff, separated by commas; Never wins. Tanks are read from the group: the group role Tank, or a raid's Main Tank assignment. A member whose role can't be read gets no tanks-only buff, and no buff kept off tanks; the button says why. A paladin's members get the first Blessing in your order that your rules give them. These rules are for buff mode only: buff back to strangers keeps the class check alone. They go with profiles and settings lines.
- **Salvation** isn't a Blessing on WoW Forever: it's worn beside one, so a member with your Salvation still gets your Blessing. It goes to everyone but tanks unless you choose otherwise.
- **On and off by itself** (Buff Back tab): buff mode can turn on when you join a group, when someone in your group dies after the group's first pull, or when someone outside your group buffs you. These are on by default; the first time each session buff mode turns itself on, chat says where to switch them off. It turns off again at the first pull, once everyone has your buffs (never assumed when someone's buffs can't be read), or after 5 minutes (adjustable; 0 for never), whichever comes first. These only end buff mode that turned itself on: buff mode you turn on yourself stays on until you turn it off. Nothing turns on in a fight; a trigger that fires in one waits for it to end. The triggers only switch buff mode; they never cast.
- **The button** shows "Buff mode: Mouse Wheel Up" above it, and stays up while buff mode is on, saying why there's nothing to buff when there isn't.
- **In a fight** the key is handed back as the fight starts, so it does its own job (the button is empty in fights anyway), and lent again when it ends. The game doesn't let key bindings change during a fight, so turning buff mode on or off in one happens when the fight ends.

The button's macro is `/cleartarget`, `/targetexact First Surname`, `/cast [help,nodead] <buff>`, then `/targetlasttarget` (or `/cleartarget` if you had no target). Targeting the exact name means a player whose name only starts the same is never buffed, and the cast only goes off on a friendly, living target, so if they can't be found nothing is cast and your target comes back. Not yet tested in WoW Forever, as it hasn't launched; the macro lives in one function, so adjusting it after the first test is a small change.

## Favour ledger

Every buff from someone outside your group, while Buff Thanks or Buff Back is on, goes in the ledger: who it was, which buffs, whether you thanked them (or why not), and whether you buffed them back. Returning favours earns a title, from **Courteous** at 10 to **Friend to All Azeroth** at 1,000. The reasons a favour wasn't thanked look like this ("thanked them a moment ago", "snoozed", "you were AFK", "on your ignore list"). It counts today's favours and your all-time totals. See it on the **Favour Ledger** page or with `/friendly ledger`. The newest 200 are kept.

## Safety

- Everything sent is cleaned first. `|` escape codes and control characters are removed, and each message is cut to 255 bytes without splitting characters.
- Output is rate-limited (one message per 1.5 s). At most 25 messages can wait, and none waits longer than 2 minutes, so a wave of guild logins can't flood chat.
- Nothing is sent during the game's chat lockdown. Messages wait until it ends.
- The 10 seconds after login or reload are ignored, and buffs you already had (re-sent by the game when you log in, reconnect or zone) are never thanked.
- Saved settings are type-checked and clamped on load, so a corrupted or hand-edited file can't break the addon. If they're damaged while you play (by another addon or a bad `/run`), they're repaired as soon as they cause an error in the addon, rather than at the next reload.
- The buff back button won't offer a buff to a player the game shows flagged for PvP unless you're flagged too (see [Buff back](#buff-back)). It's empty in a fight, and its cast only goes off on a friendly, living target.
- Buff mode only lends a key to the button with an override binding, never changes your saved key bindings, and never lends Esc or Enter. The key is handed back when buff mode ends, during fights, while the addon or Buff Back is off, and on every login or reload.
- "Secret" values from the Midnight-era API are detected and never used.
- The addon never runs text as code and doesn't read whispers or addon messages, so other players have no way to control it.
- The buff-back button's macro is built only from a checked player name and the game's own spell name, and each part is refused if it could end its line or start another command (a line break, a `|` escape code, or a leading `/`).
- A pasted settings line (`/friendly import`) is read as data only, with limits on its size and depth, and every value in it is checked like the saved file before it's used.

## Development

Requires Python 3 (to install the Lua tools) and `zip`/`unzip`.

```bash
make setup     # once: Lua 5.1, LuaRocks, busted, luacheck into ~/.cache/friendlyforever
make check     # lint + tests + package
```

- `make lint`: luacheck (Lua 5.1 rules; fails on any undeclared global)
- `make test`: busted suite in `spec/` against a simulated WoW client (`spec/support/wow.lua`)
- `make package`: builds `dist/FriendlyForever-<version>.zip` in the standard addon layout. `.pkgmeta` gives the same result with the CurseForge packager.

CI (`.github/workflows/ci.yml`) runs all three on every pull request and every push to `main`. It also builds the zip with the BigWigs packager that releases use (without uploading) and fails if its files differ from `make package`'s.

### Releasing to CurseForge

Pushing a version tag runs `.github/workflows/release.yml`, which builds with the BigWigs packager and uploads to CurseForge. [CONTRIBUTING.md](CONTRIBUTING.md#releasing-maintainer) has the full steps; in short:

1. In a pull request, bump `## Version` in `FriendlyForever.toc` and turn the top of `CHANGELOG.md` into a matching `## <version>` section, as CONTRIBUTING describes (the tests check they agree). That section becomes the CurseForge release notes.
2. After it merges, tag the merge commit and push only that tag: `git tag vX.Y.Z && git push origin vX.Y.Z` (not `--tags`). Version tags can't be moved or deleted once pushed.
3. The workflow checks that the tag is on `main` and matches the TOC version, then runs lint and tests with no secrets. Only then does the upload job wait for approval in the `release` environment. The CurseForge API token is the secret `CF_API_KEY` in that environment, and the TOC needs `## X-Curse-Project-ID`.

## License

MIT. See `LICENSE`.
