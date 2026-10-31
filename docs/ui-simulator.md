# UI simulator: known quirks

CONTRIBUTING.md's [UI simulator](../CONTRIBUTING.md#ui-simulator) section says what the simulator runs, where its output is and the safety rules for its workflow. This file adds only its known quirks and their workarounds, so the next session doesn't rediscover them. Where the two differ, CONTRIBUTING.md wins and this file is fixed.

The simulator is [wow-ui-sim](https://github.com/Osso/wow-ui-sim), adopted in #49 and #53. Unless a line says otherwise, the quirks below are at `ac893c6` (#154), the pinned commit on the simulator's `master`, and come from **#100**, which collected them for upstream (Osso/wow-ui-sim#13). The maintainer fixed most of them in `d907b88` and `ac893c6`. #154 checked each against the source and dropped the workarounds those fixes cover. When the pin moves (#53's rules), check each one again and update this file and #100.

Several workarounds live in `uitests/button_states.lua`, which sets up the buff-back button's real states (#83, #96). Its header lists them.

## The simulated game

| Quirk | Workaround | Source |
|---|---|---|
| It runs the retail 12.1.5 UI, not Forever's. Our TOC's interface (16001) counts as out of date. | The workflow sets `WOW_SIM_LOAD_OUT_OF_DATE_ADDONS=1`. | #53, `ui-sim.yml` |
| Forever's buff spells aren't in its spell data, which is retail's for every client profile. `C_Spell.GetSpellName(10938)` returns nothing (since `ac893c6`; "Unknown" before). | The spellbook fixture (`Learn` in `uitests/button_states.lua`) answers the name of the one spell a scenario needs. | #100 (7) |
| The spellbook is a fixed retail Paladin's. `A_Admin.LearnSpell`/`UnlearnSpell` (since `d907b88`) add a spell that `C_SpellBook.IsSpellInSpellBook`/`IsSpellKnown` and `IsSpellKnown` then report, but fire no event. | The fixture calls `LearnSpell`, makes the player a Priest, and fires `SPELLS_CHANGED`. | #100 (2), #154 |
| `C_Spell.IsSpellInRange` (since `ac893c6`) answers nil for a spell missing from its spell data, so for every Forever buff. It has no distance model: any visible unit is in range. | The fixture answers "in range" for whoever `UnitInRange` says is in range. | #100 (8), #154 |
| `A_Admin.AddBuff` takes a caster (since `d907b88`), but the player's aura data still names the player as its source (its `docs/admin-api/buffs.md`). | Add the buff, then fire `UNIT_AURA` again with the caster's unit token in `addedAuras`. That also lets a scenario name a bad caster (#98). | #100 (1), #154 |
| `SetInCombat` fires `PLAYER_REGEN_DISABLED`/`ENABLED` (since `d907b88`), but after the state change. That's right for the end of a fight, but at the start the game fires it just before the lockdown, the addon's last chance to change its secure button. | `Combat` fires `PLAYER_REGEN_DISABLED` itself, then calls `SetInCombat`, whose copy arrives a second time in the lockdown. That's the pessimistic case; the addon must take it in its stride, and does: `Empty` in `BuffButton.lua` never shows or hides the protected button in a lockdown, which the game would block (`spec/buffback_spec.lua`). | #100 (3), #154 |
| `SetPartySize` keeps existing members. `SetPartyMember` clears a member's auras when the name changes (since `d907b88`), so restored members come back without buffs. | Use a newly made member. | #100 (5), #154 |
| The screenshot (GUI) build starts in a demo party of 4 wearing buffs; `run-tests` starts in no party. | Save the party before the first change and put it back. | #100 (6) |
| Party changes in combat take 20–90 s, because of Blizzard's party and raid frames. | Change the party only out of combat. | #96 |
| Small text (`GameFontHighlightSmall`) is drawn about 16.5 px a line: the copy window's two-line hint measured 33 px. One line on its own reads as 12. | Space below wrapped small text by 17 px a line; `spec/layout_spec.lua` uses that for the copy window's hint. The game's height is a launch check on #50. | #116 |
| `C_Map.GetBestMapForUnit("player")` answers map 2248, though the minimap reads "Trade District" (a Stormwind subzone). 2248 isn't one of `Cities.CAPITALS`' Classic Era IDs, so quiet mode in capitals never hides the button there. | None needed. A scenario that wants a capital must replace `C_Map.GetBestMapForUnit`, and put it back. | #102 (from wow-ui-sim v0.1.36's `src/c_api/c_map.rs`; the same at `ac893c6`) |
| A scroll frame in an options panel gets no size change once the settings window lays the panel out, so its scroll child keeps the width it had before: the main panel's content measured 28 px wide (#112), the General page's the same (#52). Whether the game sends one is unconfirmed. | Both set the content's width from the scroll frame's on each show and a frame later (`FollowWidth` in `Options.lua`). A layout check against a scroll child is only as good as its width: if a `LAYOUT` line shows a frame a few pixels wide, suspect this first. | #52, #112 |
| The options tabs' rows sit on a scrolling content frame that runs below the panel's view, so a row low on a tab is outside the panel's top and bottom. | Measure a row against the content frame (`TabTextInside` does), and check only its right edge against the panel (`EndsInside`). #42's first top-up scenario measured against the panel and failed with "spills out of its frame". | #42 |
| When a region moves, only 16 links of the anchor chain below it are laid out again (`recompute_anchor_dependents` stops past depth 16, in `src/lua_api/state_render.rs`). Switching options tabs moves the message list, so rows past the 17th, the buttons and the notes below keep the last tab's places, and any up-and-down check on them reads those. | `Settle` in `uitests/scenarios.lua` sets each region's anchors again, in order, and reads its place, so each one re-lays itself and 16 more. `RowsInOrder` then fails if the rows aren't drawn top to bottom, so a stale layout can't pass. | #112 |
| `run-tests` always lays the screen out at 1600 × 1200 (`command_screen_size` in `src/bin/wow_sim/startup.rs`) and has no size option; `dump-tree` and `screenshot` take `--width` and `--height`. | The workflow runs the scenarios again through `dump-tree --exec-lua`, once per size in `LAYOUT_SIZES`, using `scripts/ui-sim-harness.lua` for `test()` and `assert*`. Each `LAYOUT` line names its resolution. | #148 |
| A size given to `dump-tree` or `screenshot` is one canvas unit a pixel (`set_screen_size`), so at 1920 × 1080 the screen is 1920 × 1080 units. The game lays a 1920 × 1080 display out on a canvas 768 units tall (about 1365 wide), so frames look about 30% smaller than players see them and have more room up and down. The simulator has `set_display_size` for the game's way, but no command or Lua call reaches it. Width is the point of the 1920 pass; the up-and-down room is not pessimistic. The game's UI scale and resolution defaults are a launch check on #50. | Read the 1920 × 1080 shots for what sits near the left and right edges, not for sizes. | #148, `display-metrics.md` and `gui_commands.rs` in wow-ui-sim v0.1.36; the same at `ac893c6`, whose new `screenshot --ui-scale` (UIParent's scale, 1.40625 for 1080 lines) could model the game's canvas for shots, not yet used |
| Colour escapes in text (`\|cff` + hex, ending `\|r`) are hidden but drawn without their colour: chat lines come out white, and a tooltip line in its default colour (the game's gold for its second line). | Check text colours against `Colours.lua` and docs/visual-style.md, or a preview drawn outside the simulator. The final look is a launch check on #50. | #46 (the `palette` shot, PR #174) |
| A line pinned to two different frames (left to one, right to another) is sized to its whole text and never wraps: `GetNumLines()` says 1. The game would wrap it. | `WrappedLines` in `uitests/scenarios.lua` works out the wrap from `CanWordWrap()` and `GetMaxLines()`. | #90, #91 |

## Blizzard's own errors

These come from Blizzard's UI code in the simulator, not from the addon. They're reported, not failed; `States.Watch` (`uitests/button_states.lua`) sorts errors by whether the addon's own error count went up (#96).

- `CompactArenaFrame.lua:318`: "secret access requires an untainted caller", when the party changes (#100, 11).
- `AddonList.lua:899`: "table index is nil", when `ADDON_ACTION_BLOCKED` arrives with no addon name (#100, 13).
- "AuraButton cannot be created by addons", from Blizzard's aura pool during `AdvanceTime` after an aura change (#100).
- `Audio.lua:179`: `GetAvailableOutputDevices` is nil, during `AdvanceTime` (new at `ac893c6`; seen in #154's first run).

Fixed by `ac893c6`, which stubs the missing functions with chosen defaults: `IsReplacingUnit` (`TargetFrame.lua:169`), `C_VoiceChat.CanAccessSettings`, `FlashClientIcon` (`LowHealthFrame.lua:176`) and `UnitPowerDisplayMod` (`ShardBar.lua:45`) (#100, 9, 10, 12).

## The test runner

| Quirk | Workaround | Source |
|---|---|---|
| Once Blizzard's UI loads, `print` goes to the chat frame, not the log. | Report lines use `A_Print` (CONTRIBUTING says so). | #53 |
| Each `A_Print` line is logged twice. | The workflow drops repeats with `awk '!seen[$0]++'`. | `ui-sim.yml` |
| `assertTrue` drops its message. | `uitests/scenarios.lua` uses its own `check()`, which calls `error(message, 3)`. | `uitests/scenarios.lua` |
| The game clock only moves when told to, with `A_Admin.SetManualClock` and `A_Admin.AdvanceTime` (in the simulator's README since `ac893c6`). `SetManualClock` can be switched on only once; a second call fails harmlessly. | `uitests/button_states.lua` uses the manual clock to get past the login grace. Anything that waits in game time still belongs in `spec/` (CONTRIBUTING). | #100 (15), #96 |
| The per-frame instruction budget (the game's script time limit) resets between tests (since `ac893c6`), but not inside one. Code that runs too long in one frame is stopped. | A long test calls `A_Admin.AdvanceTime` so a new frame starts, as the storm does after each step. | #100 (14), #96, #154 |
| Test files load in name order. | `button_states.lua` loads before `scenarios.lua`, which uses the `FriendlyForeverUIStates` it defines. | #96 |
| A test file's return value is ignored. | `uitests/scenarios.lua` returns its layout check for `spec/uitests_layout_spec.lua`. | #91 |
| A run sometimes hangs until its time limit stops it (exit 124), on any pull request and on `main`, with the same input finishing in under a minute on another run. Which scenario or step hangs isn't known yet. A pass that's stopped loses the `LAYOUT` lines it hadn't printed. | The workflow runs a stopped run once more, and names each stopped run at the top of the summary, with the last `START` line it printed, and in an annotation that holds the scenario's number. To find the scenario that hangs, read the annotations of past runs. | #173 |
| A cloud session can't read the job logs, the step summary or the artifacts: they're served from blob storage, which the proxy refuses (403). The check-run annotations API answers. | Read `gh api repos/CKozanecki/FriendlyForever/check-runs/<job id>/annotations`. | #173 |

## Screenshots

CONTRIBUTING covers what they show (our text, layout and colours, without Blizzard's art or WoW's fonts). Also:

- There's no published image at our pin, so the workflow's `simulator` job builds the simulator, with its renderer, in a sandbox, and both other jobs run that build (#53, #154).
- It renders off screen with software GL, as the runner's user with `HOME` in `/tmp`, since with every capability dropped root can't write the PNG; `xvfb-run` sat idle under Docker (#53, `ui-sim.yml`).
- Between two runs of the same code, only the simulated buff timers at the top right differ (#91). Treat other differences as real.
- A before set for comparing is hard to come by: each run replaces its PR's `ui-screenshots/pr-<n>` branch, a closed PR's branch is deleted, and `main`'s runs keep theirs only as an Actions artifact, which a cloud session's network can't reach (#115, `ui-sim.yml`). Save the PNGs of an earlier run before pushing again, or use another open PR's branch.
- The minimap and the button's border aren't drawn, so the minimap button's icon floats alone (#93).
