# Friendly Forever

A courtesy addon for **World of Warcraft: Forever** (TOC interface `16001`).

| Event | Sent to | Placeholders |
|---|---|---|
| Guild member logs in | Guild chat | `{name}`, `{fullname}` |
| A player outside your group buffs you | Say, or a whisper to them | `{name}`, `{fullname}`, `{buff}` |
| New member joins the guild | Guild chat | `{name}`, `{fullname}` |
| Player joins your group (not in battlegrounds; joins a few seconds apart share one line, which lists them all) | Party or raid chat | `{name}`, `{fullname}` |
| You join someone else's group | Party or raid chat | none |
| You rejoin a group (same leader) this session | Party or raid chat | none |

`{name}` is the first name ("Nikki") and `{fullname}` the whole name ("Nikki Shifts"). Forever characters always have a surname. The addon identifies players by their full name, so two people called Nikki are never mixed up.

Each type has its own on/off switch, a delay, a "don't repeat to the same player" cooldown (default 3 minutes; for the two hellos it's per group leader and 30 seconds) and 30 editable messages. Lines are used in a shuffled rotation: every line comes up once before any repeats, a new round never starts with the line that just ended the last one, and the rotation carries over across reloads and logins.

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

## Troubleshooting

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

**Say or whisper.** The game only allows addons to use `/say` outdoors right after a key press. Say thanks therefore wait and go out on your next key press, or when you type `/friendly say`. Turn on **"Whisper the caster instead of /say"** to whisper them immediately instead.

**The "friend" fallback** (on by default) thanks in `/say` as **"friend"** (wording configurable) when:
- the caster is unidentified, in either mode, or
- the game can't deliver the whisper ("No player named … is currently playing").

It's off while you're in a group, because party-wide buffs such as a groupmate's totems, auras or shouts can arrive with no caster, and must never be mistaken for a stranger's. Strangers the game can name are still thanked while you're grouped.

Buffs from one person that arrive before the thank-you goes out are combined: *"Thank you for the Power Word: Fortitude and Divine Spirit, Bob!"*. The repeat cooldown then stops any second thank-you.

## Safety

- Everything sent is cleaned first. `|` escape codes and control characters are removed, and each message is cut to 255 bytes without splitting characters.
- Output is rate-limited (one message per 1.5 s). At most 25 messages can wait, and none waits longer than 2 minutes, so a wave of guild logins can't flood chat.
- Nothing is sent during the game's chat lockdown. Messages wait until it ends.
- The 10 seconds after login or reload are ignored, and buffs you already had (re-sent by the game when you log in, reconnect or zone) are never thanked.
- Saved settings are type-checked and clamped on load, so a corrupted or hand-edited file can't break the addon.
- "Secret" values from the Midnight-era API are detected and never used.
- The addon never runs text as code and doesn't read whispers or addon messages, so other players have no way to control it.

## Development

Requires Python 3 (to install the Lua tools) and `zip`/`unzip`.

```bash
make setup     # once: Lua 5.1, LuaRocks, busted, luacheck into ~/.cache/friendlyforever
make check     # lint + tests + package
```

- `make lint`: luacheck (Lua 5.1 rules; fails on any undeclared global)
- `make test`: busted suite in `spec/` against a simulated WoW client (`spec/support/wow.lua`)
- `make package`: builds `dist/FriendlyForever-<version>.zip` in the standard addon layout. `.pkgmeta` gives the same result with the CurseForge packager.

CI (`.github/workflows/ci.yml`) runs all three on every push.

### Releasing to CurseForge

1. Bump `## Version` in `FriendlyForever.toc` and add a matching `## <version>` section at the top of `CHANGELOG.md` (the tests check they agree).
2. `make check`, then upload `dist/FriendlyForever-<version>.zip` on the project's Files page, with game version WoW Forever (interface 16001) and the changelog section as release notes.

Automated alternative: once the code is on GitHub and `## X-Curse-Project-ID` is in the TOC, pushing a tag (`git tag v1.5.0 && git push --tags`) runs `.github/workflows/release.yml`, which builds with the BigWigs packager and uploads to CurseForge. It needs a CurseForge API token in the repository secret `CF_API_KEY`.

## License

MIT. See `LICENSE`.
