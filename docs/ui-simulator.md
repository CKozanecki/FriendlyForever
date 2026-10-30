# UI simulator: known quirks

CONTRIBUTING.md's [UI simulator](../CONTRIBUTING.md#ui-simulator) section says what the simulator runs, where its output is and the safety rules for its workflow. This file adds only its known quirks and their workarounds, so the next session doesn't rediscover them. Where the two differ, CONTRIBUTING.md wins and this file is fixed.

The simulator is [wow-ui-sim](https://github.com/Osso/wow-ui-sim), adopted in #49 and #53. Unless a line says otherwise, the quirks below are at v0.1.36 (`3b369ee`), the pinned version, and come from **#100**, which collects them to raise upstream. When the pin moves (#53's rules), check each one again and update this file and #100.

Several workarounds live in `uitests/button_states.lua`, which sets up the buff-back button's real states (#83, #96). Its header lists them.

## The simulated game

| Quirk | Workaround | Source |
|---|---|---|
| It runs the retail 12.1.5 UI, not Forever's. Our TOC's interface (16001) counts as out of date. | The workflow sets `WOW_SIM_LOAD_OUT_OF_DATE_ADDONS=1`. | #53, `ui-sim.yml` |
| Forever's buff spells aren't in its spell data: `C_Spell.GetSpellName(10938)` gives "Unknown". A `client-wowforever` build feature exists but hasn't been tried. | A spellbook fixture answers name and ID for the one spell a scenario needs. | #100 (7) |
| The player can't learn a spell; the spellbook is a fixed retail Paladin's. | The fixture replaces `IsSpellInSpellBook`, `IsSpellKnown` and `IsPlayerSpell` for that spell, makes the player a Priest and fires `SPELLS_CHANGED`. | #100 (2) |
| There's no `C_Spell.IsSpellInRange`; the old `IsSpellInRange` returns false for a spell given by name. | The fixture answers "in range" for whoever the simulator says is in range. | #100 (8) |
| `A_Admin.AddBuff` always names the player as the caster. | Add the buff, then fire `UNIT_AURA` again with the caster's unit token in `addedAuras`. | #100 (1) |
| `SetInCombat` fires no `PLAYER_REGEN_DISABLED` or `PLAYER_REGEN_ENABLED`. | Fire them in the game's order: just before lockdown starts, and just after it ends. | #100 (3) |
| `SetTarget` and `ClearTarget` don't fire `PLAYER_TARGET_CHANGED`. | Fire it yourself. | #100 (4) |
| `SetPartySize` keeps existing members' auras, and renaming a member with `SetPartyMember` carries the old buffs over. Undo restores names, classes and levels, not buffs. | Use a newly made member. | #100 (5) |
| The screenshot (GUI) build starts in a demo party of 4 wearing buffs; `run-tests` starts in no party. | Save the party before the first change and put it back. | #100 (6) |
| Party changes in combat take 20–90 s, because of Blizzard's party and raid frames. | Change the party only out of combat. | #96 |
| Small text (`GameFontHighlightSmall`) is drawn about 16.5 px a line: the copy window's two-line hint measured 33 px. One line on its own reads as 12. | Space below wrapped small text by 17 px a line; `spec/layout_spec.lua` uses that for the copy window's hint. The game's height is a launch check on #50. | #116 |
| `C_Map.GetBestMapForUnit("player")` answers map 2248, though the minimap reads "Trade District" (a Stormwind subzone). 2248 isn't one of `Cities.CAPITALS`' Classic Era IDs, so quiet mode in capitals never hides the button there. | None needed. A scenario that wants a capital must replace `C_Map.GetBestMapForUnit`, and put it back. | #102 (from wow-ui-sim v0.1.36's `src/c_api/c_map.rs`) |
| A scroll frame in an options panel gets no size change once the settings window lays the panel out, so its scroll child keeps the width it had before: the main panel's content measured 28 px wide (#112), the General page's the same (#52). Whether the game sends one is unconfirmed. | Both set the content's width from the scroll frame's on each show and a frame later (`FollowWidth` in `Options.lua`). A layout check against a scroll child is only as good as its width: if a `LAYOUT` line shows a frame a few pixels wide, suspect this first. | #52, #112 |
| When a region moves, only 16 links of the anchor chain below it are laid out again (`recompute_anchor_dependents` stops past depth 16, in `src/lua_api/state_render.rs`). Switching options tabs moves the message list, so rows past the 17th, the buttons and the notes below keep the last tab's places, and any up-and-down check on them reads those. | `Settle` in `uitests/scenarios.lua` sets each region's anchors again, in order, and reads its place, so each one re-lays itself and 16 more. `RowsInOrder` then fails if the rows aren't drawn top to bottom, so a stale layout can't pass. | #112 |
| A line pinned to two different frames (left to one, right to another) is sized to its whole text and never wraps: `GetNumLines()` says 1. The game would wrap it. | `WrappedLines` in `uitests/scenarios.lua` works out the wrap from `CanWordWrap()` and `GetMaxLines()`. | #90, #91 |

## Blizzard's own errors

These come from Blizzard's UI code in the simulator, not from the addon. They're reported, not failed; `States.Watch` (`uitests/button_states.lua`) sorts errors by whether the addon's own error count went up (#96).

- `TargetFrame.lua:169`: `IsReplacingUnit` is nil, on `PLAYER_TARGET_CHANGED` (#100, 9).
- `C_VoiceChat.CanAccessSettings`: "settings access has not been supplied", during `AdvanceTime` (#100, 10).
- `CompactArenaFrame.lua:318`: "secret access requires an untainted caller", when the party changes (#100, 11).
- `LowHealthFrame.lua:176` and `ShardBar.lua:45`: "attempt to call a nil value" (#100, 12).
- "table index is nil", with no location (#100, 13).

## The test runner

| Quirk | Workaround | Source |
|---|---|---|
| Once Blizzard's UI loads, `print` goes to the chat frame, not the log. | Report lines use `A_Print` (CONTRIBUTING says so). | #53 |
| Each `A_Print` line is logged twice. | The workflow drops repeats with `awk '!seen[$0]++'`. | `ui-sim.yml` |
| `assertTrue` drops its message. | `uitests/scenarios.lua` uses its own `check()`, which calls `error(message, 3)`. | `uitests/scenarios.lua` |
| The game clock only moves when told to. `A_Admin.SetManualClock` and `A_Admin.AdvanceTime` exist, but are documented only in the simulator's `docs/specs/manual-simulation-clock.md`. `SetManualClock` can be switched on only once; a second call fails harmlessly. | `uitests/button_states.lua` uses the manual clock to get past the login grace. Anything that waits in game time still belongs in `spec/` (CONTRIBUTING). | #100 (15), #96 |
| The per-frame instruction budget (the game's script time limit) runs across synchronous tests, since the runner starts no new frame between them. Code that runs too long in one frame is stopped. | Call `A_Admin.AdvanceTime` so a new frame starts. | #100 (14), #96 |
| Test files load in name order. | `button_states.lua` loads before `scenarios.lua`, which uses the `FriendlyForeverUIStates` it defines. | #96 |
| A test file's return value is ignored. | `uitests/scenarios.lua` returns its layout check for `spec/uitests_layout_spec.lua`. | #91 |

## Screenshots

CONTRIBUTING covers what they show (our text, layout and colours, without Blizzard's art or WoW's fonts). Also:

- The published image is built without the renderer, so screenshots need a separate sandboxed build (#53).
- It renders off screen with software GL, as the runner's user with `HOME` in `/tmp`, since with every capability dropped root can't write the PNG; `xvfb-run` sat idle under Docker (#53, `ui-sim.yml`).
- Between two runs of the same code, only the simulated buff timers at the top right differ (#91). Treat other differences as real.
- A before set for comparing is hard to come by: each run replaces its PR's `ui-screenshots/pr-<n>` branch, a closed PR's branch is deleted, and `main`'s runs keep theirs only as an Actions artifact, which a cloud session's network can't reach (#115, `ui-sim.yml`). Save the PNGs of an earlier run before pushing again, or use another open PR's branch.
- The minimap and the button's border aren't drawn, so the minimap button's icon floats alone (#93).

## Screenshots with Forever's art (owner's Mac only)

`scripts/ui-sim-local-art.sh` takes the screenshot job's shots with Forever's own art and fonts, read from a local Forever install (#139). It's for checking the layout against the real look before launch. CI never runs it: CI has no install, and its PNGs hold Blizzard's art.

**First run** (Intel Mac, Docker Desktop running):

```
scripts/ui-sim-local-art.sh ~/ui-sim-art "/Applications/World of Warcraft"
```

- **The two arguments:** the output folder (a new one, or one an earlier run made; outside any git repository), then the install folder: the one that holds `Data/` and `.build.info`, not the `_forever_` client folder inside it. `WOW_INSTALL_PATH` can replace the second. The script never guesses the install, and stops with a message saying what's wrong and what to do (#139).
- **Docker Desktop settings** (#139):
  - **File sharing:** `/Applications` isn't shared by default. Add `/Applications/World of Warcraft` under Settings, Resources, File sharing. The defaults are `/Users`, `/Volumes`, `/private`, `/tmp` and `/var/folders`, so the output folder and the script's working folder (`~/.cache/friendlyforever/ui-sim-local-art`) need nothing. The script checks the install is shared before the long build, and says how to fix it if it isn't (#139, [Docker docs](https://docs.docker.com/desktop/settings/mac/)).
  - **Memory:** at least 8 GB (Settings, Resources, Memory); it warns below that (#139, from CI's build limit in `ui-sim.yml`).
- **How long:** the first run builds the simulator for Forever, which takes a long time (CI gives its own build up to 45 minutes). The build is kept in two Docker volumes, `ff-art-cargo` and `ff-art-target`, so later runs only take the shots: one per options tab and state, the same set as CI (the tabs come from `ui-sim.yml`'s `OPTIONS_TABS`), each stopped after at most 5 minutes. Bind mounts are slow on Docker Desktop, so the build lives in volumes, not in folders on the Mac (#139).
- **What you should see:** `==>` lines for each step, then a line per shot such as `options-buff: exited with 0 after 45 s`, then `Blizzard art from the install: textures in 16 of 16 shots, fonts (FRIZQT) in 16 of 16`, and finally `Done: all 16 shots are in …` (more as CI adds shots). The folder then holds `shots/` (`sim-game.png` to `sim-copy-window.png`, at 1920×1080 unless `--size` says otherwise), `logs/` and `README-simulated.txt`. Each run empties `shots/` first, so every PNG there is from the latest run. Blizzard's frame art (the options window's borders, the buttons) and the FRIZQT font should show, where CI's shots have grey boxes and a stand-in font. A missing shot is named at the end, and its log is `logs/sim-<name>.log` (#139).
- **If the art doesn't load:** the script checks each shot's log for the simulator's own lines saying its textures (`CASC resolver initialized from`) and fonts (`font CASC reader init complete`) came from the install. If the first shot has neither, it stops there, says which is missing and prints the first CASC error from the log, rather than taking 16 grey shots. A later shot without art fails the run at the end. ("font FRIZQT__.TTF loaded" in a log is only a timing line: it's printed even when the font fell back to a system one.) (#139)
- **Size:** 1920×1080 by default, what most players play at, the owner's choice; CI's shots stay at 1024×768 (#139, and #148 for a 1920×1080 pass in CI). `--size WxH` takes any size from 640x480 to 3840x2160, such as `--size 1024x768` to compare with CI's shots (#139).
- **Other options:** `--product CODE` picks another CASC product if the install's isn't `wowf` (the script lists the ones it finds). `UI_SIM_SHOT_SECONDS` changes the 300 s limit per shot (#139).

**What it runs, and why it's safe** (CLAUDE.md's rules for external tools, as in #49 and #53):

- **Pins:** the same simulator commit and base image digests as `ui-sim.yml`, built with the `client-wowforever` profile. Never upstream's release binaries. A repo test checks that they match (#139).
- **Forever's UI code:** Gethe's `wow-ui-source` at `ca8368f` (1.60.1.70532), the commit the simulator itself pins in `data/blizzard-ui-builds/wowforever.json`. Its files are exactly the simulator's `data/blizzard-ui-files/wowforever.txt`. The script checks both, and marks the cache complete, so the simulator never syncs UI code from the install or Blizzard's CDN (#139).
- **Network:** only `cargo fetch` has it, to download the locked crates, and it runs none of their code. The build and every shot run with `--network none` (#139, as `ui-sim.yml`).
- **What a shot sees:** read-only, only the install's `Data/` (the game's CASC storage, where the art is) and `.build.info`, plus a minimal `.product.db` the script writes. Never `WTF/` (it holds the account name and saved settings), `Interface/AddOns`, a version folder such as `_forever_/` or the whole install. Its CASC code (cascette-rs's `read_installed_product` and `Installation::open`, at the commits the simulator's `Cargo.lock` pins) only opens these for reading. It would create `Data/data` or `Data/indices` if they were missing, so the script checks they're there first (#134, #139).
- **Why the script writes `.product.db`:** the simulator finds the active build only through `.product.db`, and its decoder (cascette-rs's `product_db.rs`, after TACTLib's `ProtoDatabase.cs`) can't read the live launcher's: the owner's first run failed with `invalid protobuf: … Database.product_install: invalid wire type value: 7`, and every shot came out grey (#139). So the script reads the product's one active row from `.build.info` (its build key, install key and version, each checked), checks its build config is in `Data/config/`, and writes just the fields that decoder reads: `product_install { product_code, cached_product_state { base_product_state { current_version_str, active_build_key, active_install_key } } }`. The launcher's own `.product.db` is never mounted or read (#139).
- **What a shot can write:** its root file system is read-only. Only a tmpfs (`HOME` and `XDG_CACHE_HOME`, where the art it extracts goes) and the output's `shots/` folder are writable. The script writes `logs/` and the README itself, beside `shots/`, so no container can plant a link there that the script would then write through. An output folder holding anything else, or a link, is refused. No capabilities, no privilege escalation, no secrets, killed at its time limit, and never left running, even after Ctrl-C (#139).
- **Forever's UI code in a shot:** it's mounted read-only at `/forever-ui` and linked into the simulator's cache on the tmpfs. Mounted there directly, its parent folders would belong to root, and the simulator couldn't write the art it extracts beside it (#139).

**The PNGs hold Blizzard's art:**

- **Keep them on your Mac:** never commit, push, attach to a pull request or upload them. The script refuses an output folder inside a git repository, and `.gitignore` covers `sim-*.png` and the likely folder names as a backstop (#139).
- **Label public use:** any shot used publicly, such as on CurseForge's Media tab, is labelled as simulated, not a real screenshot. Real in-game screenshots (#50's checklist) stay the main media. Renders made from the game's files aren't clearly covered by Blizzard's terms (#134).

**Launch checks** (#50):

- **Install layout:** on the owner's Mac (pre-launch client, 2026-10-29), `/Applications/World of Warcraft` is one install shared by every version: one `Data/`, `.build.info` and `.product.db`, with Forever's client in `_forever_` beside `_retail_` and the others (#139). Guides say the same ([mobalytics](https://mobalytics.gg/wow-forever/profile/broog/guides/how-to-install-addons-wow-forever), [CurseForge blog](https://blog.curseforge.com/wow-forever-migrate-addons-beta-to-live/)). Whether the launch client keeps it: **launch check** (#50).
- **Product code:** the simulator's Forever profile reads CASC product `wowf` (`src/asset_resolver_config.rs` at `3b369ee`), while its asset loader's tests use `wow_forever`. Which the live client uses: **launch check** (#50); the script lists the install's products if `wowf` isn't one (#139).
- **The Forever profile itself:** our scenarios have only run on the retail profile in CI. Forever's art and UI code may show quirks the retail runs don't (#100 item 7, #139).
