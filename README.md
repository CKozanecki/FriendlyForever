# Friendly Forever

A courtesy addon for **World of Warcraft: Forever** (TOC interface `16001`).

| Event | Sent to | Placeholders |
|---|---|---|
| Guild member logs in | Guild chat | `{name}`, `{fullname}` |
| A player outside your group buffs you | Say, or a whisper to them | `{name}`, `{fullname}`, `{buff}` |
| New member joins the guild | Guild chat | `{name}`, `{fullname}` |
| Player joins your group (not in battlegrounds; joins a few seconds apart share one line, which lists them all; in a raid, only the leader welcomes, at most once every 30 seconds) | Party or raid chat | `{name}`, `{fullname}` |
| You join someone else's group | Party or raid chat | none |
| You rejoin a group (same leader) this session | Party or raid chat | none |

`{name}` is the first name ("Nikki") and `{fullname}` the whole name ("Nikki Shifts"). Forever characters always have a surname. The addon identifies players by their full name, so two people called Nikki are never mixed up.

Each type has its own on/off switch, a delay, a "don't repeat to the same player" cooldown (default 3 minutes; for the two hellos it's per group leader and 30 seconds) and 30 editable messages. Lines are used in a shuffled rotation: every line comes up once before any repeats, a new round never starts with the line that just ended the last one, and the rotation carries over across reloads and logins.

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

So "{greeting}, {name}! {blessing}" comes out as "Throm-ka, Thrall! Strength and honor." from an orc, or "Ishnu-alah, Thrall! Elune light your path." from a night elf. The same words aren't used again until a few others have been. Use these in your own lines too.

The 1.5 to 1.6 default lines are still there: each tab's **Load casual lines (1.6)** button puts them back, and **Load fantasy lines** loads the new ones. Lines you edited are never replaced by an update.

## Install

With the CurseForge app, search for **Friendly Forever** and install it for WoW Forever.

By hand: unzip `FriendlyForever-<version>.zip` (or copy the `FriendlyForever` folder) into your WoW Forever install's `Interface/AddOns/` folder, for example:

```
World of Warcraft/_classic_beta_/Interface/AddOns/
```

## Use

- **Options:** Esc → Options → AddOns → Friendly Forever, or type `/friendly`
- **Minimap button:** left-click opens options, right-click turns the addon on or off, drag to move it
- `/friendly on | off | toggle | test | say | minimap | help` (`/ffr` also works)
- `/friendly snooze [minutes] | off`: send nothing for a while (15 minutes by default, up to a day). It holds across a reload.
- `/friendly ignore [name]` and `/friendly unignore <name>`: never greet, welcome or thank a player. Use the full name ("Nikki Shifts"); with no name it takes your target, or lists the names when you have no target.
- `/friendly ledger [count] | clear`: the favour ledger (see below).
- `/friendly profile [new | use | delete] <name>`: profiles. Each character switches to the profile it used last when it logs in.
- `/friendly export` and `/friendly import [undo]`: your settings as one line of text, to keep or share. Importing never turns the addon on or off and only adds to your ignore list; `import undo` puts your settings back.
- The **General** page under Friendly Forever in the AddOns options has all of these as buttons.
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

## Favour ledger

Every buff from someone outside your group, while Buff Thanks is on, goes in the ledger: who it was, which buffs, and whether you thanked them, or why not ("thanked them a moment ago", "snoozed", "you were AFK", "on your ignore list"). It counts today's favours and your all-time totals. See it on the **Favour Ledger** page or with `/friendly ledger`. The newest 200 are kept.

## Safety

- Everything sent is cleaned first. `|` escape codes and control characters are removed, and each message is cut to 255 bytes without splitting characters.
- Output is rate-limited (one message per 1.5 s). At most 25 messages can wait, and none waits longer than 2 minutes, so a wave of guild logins can't flood chat.
- Nothing is sent during the game's chat lockdown. Messages wait until it ends.
- The 10 seconds after login or reload are ignored, and buffs you already had (re-sent by the game when you log in, reconnect or zone) are never thanked.
- Saved settings are type-checked and clamped on load, so a corrupted or hand-edited file can't break the addon.
- "Secret" values from the Midnight-era API are detected and never used.
- The addon never runs text as code and doesn't read whispers or addon messages, so other players have no way to control it.
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
