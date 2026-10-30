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
| `run-tests` always lays the screen out at 1600 × 1200 (`command_screen_size` in `src/bin/wow_sim/startup.rs`) and has no size option; `dump-tree` and `screenshot` take `--width` and `--height`. | The workflow runs the scenarios again through `dump-tree --exec-lua`, once per size in `LAYOUT_SIZES`, using `scripts/ui-sim-harness.lua` for `test()` and `assert*`. Each `LAYOUT` line names its resolution. | #148 |
| A size given to `dump-tree` or `screenshot` is one canvas unit a pixel (`set_screen_size`), so at 1920 × 1080 the screen is 1920 × 1080 units. The game lays a 1920 × 1080 display out on a canvas 768 units tall (about 1365 wide), so frames look about 30% smaller than players see them and have more room up and down. The simulator has `set_display_size` for the game's way, but no command or Lua call reaches it. Width is the point of the 1920 pass; the up-and-down room is not pessimistic. The game's UI scale and resolution defaults are a launch check on #50. | Read the 1920 × 1080 shots for what sits near the left and right edges, not for sizes. | #148, `display-metrics.md` and `gui_commands.rs` in wow-ui-sim v0.1.36 |
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
