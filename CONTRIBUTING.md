# Contributing

Ideas, bug reports and pull requests are welcome. Every change starts from an issue, so we can agree on the approach before you write it and trace it afterwards. For a small fix, just open the pull request; the maintainer opens its issue if it doesn't have one.

## How changes land

`main` is protected: every change, the maintainer's own included, goes through a pull request.

1. Start from an issue (see [Specs and traceability](#specs-and-traceability)).
2. Branch from the latest `main`. By convention the name starts with the issue number, optionally after a prefix: `57-quiet-in-cities`, `claude/57-quiet-in-cities`. Each pull request gets a new branch.
3. Make the change, with a test in `spec/` for any behavior change.
4. Run `make check` locally.
5. Open the pull request as a **draft** and fill in the template, with `Closes #<issue>` for each spec it completes. Mark it ready for review when it is (see [Ready for review](#ready-for-review)). CI must pass and review conversations must be resolved before it can merge. **A pull request can merge as soon as the required `check` is green** (#241): the report-only jobs (the UI simulator, screenshots, CodeQL) never gate a merge, and nobody waits for them unless the change is a UI change the maintainer wants to look at. (An agent's UI change still has its screenshots looked at by the testing review before it is ready.) The maintainer reviews outside pull requests. Their own get an automated review, because GitHub doesn't let authors approve their own pull requests, so `main` requires passing CI rather than an approval.
6. Merges are squash merges, so each PR becomes one commit on `main`, its title ending with the pull request's number, as in `(#54)`. Numbers in commit titles are pull requests; numbers at the end of changelog entries are issues.

## Specs and traceability

Every change can be traced from its spec to its code, tests, pull request and release.

- **Specs are issues.** A feature or fix starts as an issue with a **Spec** and testable **Acceptance criteria**. Each phase of work is a parent issue, and its features are sub-issues. Decisions and changes of scope are written on the issue, not left in chat.
- **Acceptance criteria say which kind of test proves them.** This is written in the criterion itself (not a GitHub label):
  - **white:** expected use gives the expected result;
  - **black:** bad or error input is handled correctly;
  - **red:** chaos (random storms, damaged state) never crashes the addon, and anything damaged heals itself.
- **Pull requests** say `Closes #<issue>` for each spec they complete (one keyword per issue: `Closes #1, closes #2`) and copy its acceptance criteria into the description as a checklist, ticked as they're met. The maintainer ticks them on the issue when merging.
- **Tests:** a spec file written or changed for an issue says so in a comment on one of its first five lines, in exactly this form: `-- Spec: #27` (or `-- Spec: #27, #52`). A repo test checks the form. Test names repeat the acceptance criteria in words; reviewers check that.
- **Changelog** entries are bullets, one per change, and end with the issues they come from: `(#27)`, or `(#27, #52)` for several. A pull request adds its note as a file of its own, never in `CHANGELOG.md`: [Changelog notes](#changelog-notes) below. The release notes on CurseForge leave the tags out.
- **Releases:** the Release workflow creates the GitHub release for each tag. Its notes are that version's changelog section without the issue tags, the same notes CurseForge shows. The changelog's tags trace each entry to its issues, and squash-merge titles trace each commit to its pull request.

### Changelog notes

Each pull request with a change players (or the release) should hear about writes its note as a file of its own, so two pull requests never edit the same lines (#261). This is the one place the rule is written; everything else links here.

- **The file:** `changes/<issue>.md`, holding the one bullet the change would have had in `CHANGELOG.md`: a bold lead, the text, and its issues at the end, `(#<issue>)`, which must include the issue in the name. A second pull request on the same issue uses `changes/<issue>-<word>.md`, such as `changes/256-part2.md`. One bullet per file; it may wrap, and may have indented sub-bullets, but no blank lines or headings.
- **Checked by `make check`:** every file in `changes/` must be named that way and be such a bullet. An empty file, a bullet without its issue, or any other file there fails with a message naming the file.
- **The release PR gathers them** with `make changelog VERSION=x.y.z` (preview first with `make changelog-preview VERSION=x.y.z`, which changes nothing). It writes the new `## x.y.z` section at the top of `CHANGELOG.md`: any bullets still under `### Unreleased`, as written, then each fragment's bullet by issue number. It deletes the fragments, and changes nothing if any of them is wrong. Notes about the whole release (such as "This version adds files") are then added to that section by hand.
- **Nothing is left out:** `make release-notes RELEASE=1` fails while a note waits in `changes/` or under `### Unreleased`. CI runs it on a pull request that changes the TOC version, and the Release workflow runs it before anything else is approved.
- **Moving over:** bullets under `### Unreleased` on `main` when this rule arrived stay valid and are gathered with the fragments. A pull request that still has an Unreleased line moves it to a fragment the next time it merges `main`.
- **Old releases:** a repo test checks the tags of every entry of the released version once it's past 0.6.0, and of any bullet under `### Unreleased`.

### Review loops

Pull requests written by an agent go through two review loops before the maintainer's review: a Lua architecture review, then a Lua testing review, each repeated until it approves. Every finding is fixed. Reviewers report only real problems, things that would actually go wrong for the addon, its players or its releases, and never invent issues or stretch for unrealistic edge cases to keep a loop going. "Everything is OK" is a perfectly good review when it's true. Claude runs them with the `lua-architect` and `lua-tester` agents in `.claude/agents/`, which point back here.

Some cases need less review, or a faster order (#217; owner, 2026-11-14). An approved review is never repeated; only a change it hasn't seen goes back.

- **A merge that touches none of the PR's files: CI only.** After `main` is merged into a ready PR, the driver compares two lists, taken before the merge: `git diff --name-only <old main>..<new main>` (what the merge brings in) and `git diff --name-only origin/main...HEAD` (the PR's own files). If the merge was clean (no conflict resolved) and the lists share no file, the driver runs `make check`, confirms CI is green, puts both lists in the description and announces the PR ready again. The reviewers don't confirm. If any file is in both lists, or a conflict was resolved, the reviewers confirm the merge and the resolution only, as before. **One combined pass for a merge whose changes don't overlap:** if the merge was clean and, in every file that is in both lists, the regions (hunks) each side changed don't overlap, a single combined review pass confirms it: the `lua-architect` and `lua-tester` files run as one. Overlapping hunks, or a conflict that was resolved, keep both loops.
- **A docs-only pull request: CI plus one review.** A PR that changes only docs, rules, templates or `--` comments gets CI and one combined review: the `lua-architect` and `lua-tester` files run as a single pass. It has no mutation pass and no second loop. The comments-stripped (compiled listing) check proves no code changed. Any `*.lua` change outside comments, any `*.toc` or `*.xml` change and any workflow file is never docs-only, and a code PR still gets both review loops once.

- **Parallel reviews for a PR that isn't safety-critical.** For a PR that changes only docs, CI, the test harness or UI text, the architecture and testing reviews may run at the same time. If the architect requests changes, the tester re-checks only what changed. A safety-critical PR (casting, chat sending, saved settings, secret values, buff targeting and PvP rules) keeps the strict order: architecture first, then testing. This list is wider than the mutation-check definition below (it adds chat sending, buff targeting and PvP rules), and a PR that changes anything beyond those four kinds keeps the strict order too.

**Mutation checks are for safety-critical code only (#217).** Safety-critical code is code where a mistake could cast wrongly, mishandle a secret value, or damage saved settings. Mutations run once (owner, 2026-11-14). The developer changes every new or changed safety-critical line temporarily, confirms a test fails, restores the file exactly, and lists each mutation and its result in the PR. The testing reviewer checks that list and the tests, and doesn't repeat the list; it runs only 3 to 5 targeted mutations of its own, aimed at what the list may miss: compound conditions, comparisons turned round, a single unreadable value. A merge confirmation mutates only the lines the merge changed or resolved. For other code, the tests and the review are enough.

For a pull request that changes what players see, the Lua testing review also looks at its [UI simulator](#ui-simulator) screenshots and layout checks, and decides whether they're right. The maintainer doesn't review screenshots.

### Ready for review

A pull request is **ready for review** when all of these hold:

- CI is green on the latest commit;
- the description matches the final code;
- the branch is up to date with `main` and has no conflicts (a branch that is only behind `main` counts as up to date: see [Only behind `main`](#only-behind-main));
- for pull requests written by an agent: both of its review loops (Lua architecture, then Lua testing) have approved, with every finding fixed (a docs-only pull request needs its one review, and a merge that touches none of its files needs only CI: see [Review loops](#review-loops));
- it has no open question for the maintainer (#215).

**A pull request with an open question for the maintainer is not ready.** Whoever drives it asks the maintainer first (a session does so through the coordinator) and marks it ready only after the answer is applied. Its description has no "decisions for the maintainer" section when it is ready. A choice the driver made by following the spec is written plainly as a decision taken, not as a question. If the driver is unsure, that is a question, and the pull request waits. The coordinator doesn't call a pull request ready to merge while a question on it is open.

Then whoever drives it marks it ready (GitHub's **Ready for review** button, out of draft) and says so in a comment, so the maintainer never has to ask.

It is **ready to merge** when, on top of that, every review conversation is resolved.

#### Only behind `main`

When another pull request merges, GitHub marks the next ready one out of date (#229). The maintainer decided on 2026-11-09 that the cheaper fix is for them to click GitHub's **Update branch** button themselves. It depends on the two file lists of the file-disjoint rule in [Review loops](#review-loops):

- **No file in both lists and no conflict: update branch only.** The developer does nothing: no merge, no push, no reviewer re-run. The "up to date with `main`" box counts as met; the coordinator's message to the maintainer, naming the pull request and the two file lists, is the record. The maintainer clicks **Update branch**, CI runs on the new head, and they merge when `check` is green.
- **A file in both lists, or any conflict: developer must merge.** Unchanged: the developer merges `main`, resolves, and the reviewers confirm the merge and the resolutions.

The coordinator tells the maintainer which case each waiting pull request is in, naming it, so the maintainer never has to work it out.

## Local setup

You need Python 3, `curl`, `make`, a C compiler, `zip` and `unzip`, and on Linux the readline headers (`libreadline-dev` on Ubuntu). Everything else installs into `~/.cache/friendlyforever`:

```
make setup   # the pinned Lua toolchain (re-running it is quick)
make check   # lint, tests, release zip
```

`make setup` runs `scripts/dev-setup.sh`, the one toolchain setup that local runs, CI, releases and claude.ai sessions all use (#103). It installs these versions:

| Tool | Version |
| --- | --- |
| hererocks | 0.25.1 |
| Lua | 5.1.5 |
| LuaRocks | 3.8.0 |
| busted | 2.2.0-1 |
| luacheck | 1.2.0-1 |

busted's and luacheck's own dependencies are pinned in the script too.

- **Checksums:** every file it downloads must match its SHA-256 in `scripts/dev-setup.lock` before it's used. If one doesn't, or a download fails, it stops before installing anything. Never work around a mismatch: it means the file isn't the one that was reviewed.
- **Re-running:** once the pinned tools are installed and run, it does nothing and downloads nothing. A changed pin, or a damaged or half-finished install, is installed again from scratch.
- **Changing a version:** change the script and `scripts/dev-setup.lock` together, with each new checksum taken from a published source other than the download itself. Say in the pull request where each one came from.

### Download hosts

The script downloads only from these hosts. A host in brackets is a fallback, used only when the first can't be reached; it serves the same files.

| Host | What |
| --- | --- |
| `files.pythonhosted.org` | hererocks |
| `www.lua.org` (`archive.ubuntu.com`) | Lua |
| `luarocks.github.io` | LuaRocks |
| `luarocks.org` (`raw.githubusercontent.com`) | busted, luacheck and their dependencies |
| `archive.ubuntu.com` | the sources of lua-term and mediator_lua, two of busted's dependencies |

If a download fails, the script names the host. Behind a firewall or network policy, allow every host above.

### claude.ai environment

Claude's cloud sessions get the toolchain from the environment's setup script. The maintainer sets these in the environment's settings (the environment menu in a session's title bar, then **Edit**):

- **Network access:** keep the default list of package managers, and add these allowed domains, one per line:

  ```
  www.lua.org
  luarocks.github.io
  luarocks.org
  ```

  The default list already has `files.pythonhosted.org`, `archive.ubuntu.com` and `raw.githubusercontent.com`.
- **Setup script:** one line.

  ```
  make -C /home/user/FriendlyForever setup
  ```

  The environment keeps the installed tools for its later sessions. If the script fails, sessions don't start, and its log names the file and the host. Sessions start with the tools installed, so `make setup` in a session is a no-op check (re-running it is quick); a session that starts without them runs it itself.

CI runs the specs in four parallel shards (`scripts/test-shards.sh` splits the files, the slow ones spread out; `make test` still runs them all, and `make test SPECS="spec/a_spec.lua"` runs some). `check` is the one required job on `main`: it passes only when lint and packaging and every shard did, and when every spec file is in exactly one shard (#218).

CI also builds the zip with the BigWigs packager that releases use, and fails if its files differ from `make package`'s. If that check fails, add the new top-level file to `.pkgmeta`'s `ignore` list, or to the TOC if it should ship.

## UI simulator

The **UI simulator** workflow loads the packaged addon in [wow-ui-sim](https://github.com/Osso/wow-ui-sim), a headless WoW client that runs Blizzard's real UI code (#49). It plays WoW Forever: the simulator's Forever profile, with Forever's own UI code and spell data (#160). It runs on every pull request and push to `main`, but its `changes` job skips the simulator unless a file that can change what players see was touched (#218): the root Lua files that create frames (`grep -l CreateFrame *.lua`, plus `OptionsIndex.lua`, `Nameplates.lua`, `Colours.lua`, the palette every colour comes from, and `BuffData.lua` and `BuffRules.lua`, which decide text the Buff Back tab shows (#226)), the TOC, `*.xml`, `Media/`, `uitests/`, `.pkgmeta`, `scripts/package.sh`, `scripts/ui-sim-harness.lua`, the spell data check and the copy it checks against (`scripts/sim-spell-check.py`, `scripts/data/forever-spells.json`, #160) and the workflow itself; a hand start always runs it. Two changes to those files can't change what players see, so they skip it too (#241): a TOC change to only its `## Version:` line (the `## Interface:` line and the file list still run it), and a change to a root Lua file that touches only `--` comments and blank lines. The `changes` job reads both versions of the file with `git show` and compares them as text, running nothing from them; a file added or deleted, a NUL byte, a long bracket (`[[` or `[=`), a line ending in a backslash, or a carriage return inside a line of the TOC or the Lua file, is doubt. A skipped job counts as passing, and doubt means it runs. It's report only: it never fails CI, and nothing it produces is trusted.

- **What it runs:**
  - **Lua errors** from loading, and the addon's frame tree.
  - **UI scenarios** in `uitests/scenarios.lua`, including the layout checks: text stays inside its frame, and frames stay on screen. Each layout check prints a `LAYOUT` line. The scenarios run in `run-tests`, then again at 1024 × 768 (the narrowest layout) and 1920 × 1080 (what most players use) through `dump-tree`, since `run-tests` has no size option (#148). Each `LAYOUT` line names its resolution.
  - **Screenshots** of the game screen, each options tab and page, the copy window and the buff-back button. Each options tab's shot is named after it, such as `options-buff-back.png` (#112). The Buff Back tab also has `options-buff-back-lower.png`, the tab scrolled to its lower rows, from "Use group versions" down (#254). Every shot is taken at 1024 × 768 and again at 1920 × 1080, saved beside it as `<name>-1920x1080.png` (#148).
- **Where to look:** the run's summary has the errors, the scenarios and the layout lines. For a pull request from this repository, the screenshots are committed to the branch `ui-screenshots/pr-<number>`, replaced on every run. The branch is deleted when the pull request closes, merged or not, so look at the screenshots before then; the testing review already does, before the pull request is ready. To view them: `git fetch origin ui-screenshots/pr-<number>`, then open the PNGs, or browse the branch on GitHub.
- **The simulator build is cached** (#170): the `simulator` job saves the finished, staged build, keyed on a hash of every pin and build setting in the workflow's `env` (the `SIM_`, `BLIZZARD_`, `BUILD_` and `SPELL_` variables: the commits, the profile, the build base and toolchain, the package list, the cargo features, the strip setting, and the spell data's hosts and hash), the hash of `ui-sim.yml` itself, so editing any build or staging step, even a literal flag, also misses, and the hash of the two files the spell data check reads. On a hit it skips the fetch, the image, `cargo fetch`, `cargo build` and the spell data download; any change to one of those misses and rebuilds. A pull request's cache is visible only to it (it can read `main`'s); a restored build is as untrusted as a fresh one, so the job checks it holds only plain files, and that its spell data has the pinned hash, after a restore, and before saving a new build and uploading it. `spec/repo_spec.lua` fails if a variable the build uses is left out of the key.
- **Runs that hang** (#173): a simulator run that reaches its time limit is stopped (exit 124) and runs once more. A run stopped is named at the top of the summary, with the last scenario it started (each scenario prints `START <number> <name>` first) and the end of its log, and in an annotation on the run. A warning annotation means it was stopped twice and its results, `LAYOUT` lines included, are incomplete; a notice means the retry ran. The job stays green either way.
- **Clean-up** (#106): the **UI screenshots clean-up** workflow deletes the branches.
  - **When a pull request closes,** it deletes that pull request's branch, if there is one. It never fails the pull request's checks.
  - **The sweep** deletes `ui-screenshots/pr-N` wherever pull request N is closed, and keeps every other branch. Run it now for the branches left from before the clean-up existed, such as `pr-88` and `pr-91`, and any time branches pile up (a simulator run that finishes after its pull request closes can publish its branch again). To run it: **Actions**, then **UI screenshots clean-up**, then **Run workflow**. Only the maintainer can: sessions can't delete branches.
  - **Safety:** both delete only branches named exactly `ui-screenshots/pr-<digits>`, so never `main` or a work branch. The close-time one builds the name only from the pull request's number. Neither checks out or runs anything from a pull request, and only those two jobs may write. A branch that's already gone is fine. `spec/repo_spec.lua` checks all of this.
- **What the screenshots show:** our text, layout and colours. Blizzard's art and WoW's fonts aren't there, so sizes are approximate. Layout checks catch the problem whatever the font. The final look was checked in game on launch day (Nov 4). Fetching Blizzard's art (level C) is the maintainer's call.
- **Adding a scenario:** write it in `uitests/scenarios.lua` with the simulator's `test()` and `assert*` functions, and add any new global it reads to `uitests/**` in `.luacheckrc`. Report lines go through `A_Print`, since Blizzard's UI sends `print` to chat. Put back anything a scenario changes, even when it fails. `uitests/` never ships. Anything that waits in game time belongs in `spec/`, whose client controls the clock.
- **Safety:** the simulator is unvetted code. Changes to the workflow keep every one of these, and `spec/repo_spec.lua` checks them:
  - the simulator built here from its source, pinned by commit, with the build and render images' bases pinned by digest. Never a published image or release binary. Read the source at a new commit before moving the pin, and post the review on the issue first (#154);
  - the simulator, and its build (which runs its build scripts and macros), in containers with no network, no capabilities and read-only sources. Only their output folders are writable. Two steps have network, and neither builds or runs the simulator:
    - the one that downloads its locked crates: `cargo fetch` has network, but runs none of their code;
    - the one that downloads Forever's spell data with the simulator's own tool (#160, the maintainer's decision of 2026-10-30). Its container is on a Docker network with no route out, and reaches only a proxy that allows nothing but an HTTPS tunnel to a host in `SPELL_DATA_HOSTS` on port 443 (no other host or port, and no plain HTTP). The file it writes must have the SHA-256 pinned as `SPELL_DATA_SHA256`, or the job stops before anything is cached, uploaded or run; `scripts/sim-spell-check.py` then proves every spell in `scripts/data/forever-spells.json` has the same rows in it. When the pin moves and the hash changes, take the new one from that step's annotation only after reading the download code at the new commit;
  - no secrets, and read-only access for every job but the one that publishes screenshots;
  - that publishing job runs nothing from the simulator or the pull request. It only checks that each file is a PNG of a sane size, then commits it;
  - anything the simulator or a shot chooses (file names, logs) reaches the job log only through the workflow's `shown` filter, so no line of it can be read as a workflow command (#153);
  - never the simulator project's own Action.

## Ground rules for addon code

- WoW runs Lua 5.1. Don't create globals: `.luacheckrc` lists the only ones allowed, and the lint fails on anything else.
- All chat output goes through `ChatQueue` so cooldowns, lockdown and rate limits apply.
- Never change a player's game settings (CVars) without an explicit action from them (a click, or `/friendly nameplates`).
- Keep saved variables backward compatible. Old `FriendlyForeverDB` contents must still load.

## Releasing (maintainer)

[docs/launch-day-runbook.md](docs/launch-day-runbook.md) is the ordered in-game test pass (from #50), completed on launch day, and the steps to 1.0.0.

0.8.0 was the first file on CurseForge and 1.0.0 is the launch release. A tag uploads as a normal release; the packager marks a file alpha or beta only when its tag contains that word, and the Release workflow accepts only a tag that is exactly `v` plus the TOC version. No beta route is set up yet.

**A patch release of documentation-only fixes is one pull request** (#241). When everything a patch release carries is documentation, comment or changelog fixes, the pull request with the fix also bumps the TOC version and gathers the changelog notes ([Changelog notes](#changelog-notes)), so the checks run once, not twice. A release with code changes keeps its own release PR.

Pull requests between releases add their notes as `changes/<issue>.md` files; the release PR gathers them into `## x.y.z` ([Changelog notes](#changelog-notes)).

**Before the release PR, decide whether the walkthrough needs a new step** (#169). The first-install walkthrough (`Walkthrough.lua`) runs once. A feature worth explaining to players who already finished it gets a step in the same PR that adds the feature, or in a PR before the release. It is a deliberate choice, not automatic: most releases add no step, and then nothing changes.

- **Adding a step:** give it `since = <the new version>` and raise `Config.WALKTHROUGH_VERSION` to that number, which is a small integer counted in steps added, not the addon's version. Steps stay in the order they were added; put a new one before the closing "That's it" step. A test in `spec/walkthrough_spec.lua` fails if the version and the steps' `since` numbers disagree. Keep the new step's title to about 35 characters, so "What's new: <title>" fits the window's title line. Update the specs that list the steps and the pages they open (`spec/walkthrough_spec.lua`) in the same PR.
- **What players see** after updating: a new player and the replay from Start here see every step; a player who finished or skipped an older version sees only the steps added since, titled "What's new"; an up-to-date player sees nothing. Finishing or skipping saves the version. Never lower the version: a saved version above it is read as damaged, and the player sees every step once.
- **Not for every change:** a fix, or a setting players won't miss, needs no step. If a release adds one, say so in the changelog entry.

**When the supported game version changes, re-extract the spell data and re-run the generator, and commit the output** (#209). The buff table (`BuffTable.lua`) is generated, never edited by hand, and the addon looks no spell up while players play. A maintainer or a session does this, never in CI. (The UI simulator workflow downloads the same data for the simulator alone, and checks it against this file, #160; nothing it downloads is committed or ships.)

1. Extract Forever's spell data with upstream's `wow-cli casc sync-forever-spells` (project Osso/wow-ui-sim). It downloads Blizzard's data, so follow [AGENTS.md](AGENTS.md)'s "External code and tools": pin the commit, read the download and extraction source first and post the review on the issue, build with no secrets, give it network only for the download, run nothing from it in CI. The result must match the SHA-256 upstream records for that build (`docs/specs/forever-spell-data.md`); if the build is new, report its hash and the evidence.
2. Save the file as `scripts/data/forever-spells.json`.
3. Run `python3 scripts/gen_spell_table.py --spells scripts/data/forever-spells.json --buffs scripts/spell-buffs.json --out BuffTable.lua`. It prints a report of every buff and spell found or not found, and exits non-zero without writing anything if the data is damaged. Put the report in the PR.
4. `make check` runs `spec/bufftable_spec.lua`, which checks the committed table is valid and that the generator reproduces it exactly from the committed source. That is all that is checked automatically; the extraction itself is only as good as the review of upstream's code and the hash.

To release:

1. In a PR: bump `## Version` in `FriendlyForever.toc`, run `make changelog-preview VERSION=x.y.z` and then `make changelog VERSION=x.y.z` to gather the notes into `## x.y.z` at the top of `CHANGELOG.md` ([Changelog notes](#changelog-notes)), and add notes there for anything missing. CurseForge shows only that section (`make release-notes RELEASE=1` previews it, and fails if a note was left behind).
2. After it merges, tag the merge commit and push the tag: `git tag vx.y.z && git push origin vx.y.z`. Version tags can't be moved or deleted once pushed, so double-check the commit first. The GitHub release isn't made by hand: the workflow makes it in step 3.
3. The Release workflow's `verify` job checks that the tag is on `main` and matches the TOC, with read-only access and no secrets. Then it asks GitHub whether `main`'s required `check` passed on that exact commit (#241): if it did, lint and the tests already ran there and aren't run again; if that run hasn't finished, or there is none, `verify` runs lint and the tests itself, as before; if it failed, the release stops (re-run `main`'s failed CI jobs on that commit, then re-run the Release workflow). After that, the `release` job waits for your approval in the `release` environment, checks that the CurseForge project ID and key are set, and uploads. The packager uploads to CurseForge and creates the GitHub release for the tag, with the same notes and the zip attached. Once the job is green, there's nothing left to do.
