# Contributing

Ideas, bug reports and pull requests are welcome. Every change starts from an issue, so we can agree on the approach before you write it and trace it afterwards. For a small fix, just open the pull request; the maintainer opens its issue if it doesn't have one.

## How changes land

`main` is protected: every change, the maintainer's own included, goes through a pull request.

1. Start from an issue (see [Specs and traceability](#specs-and-traceability)).
2. Branch from the latest `main`. By convention the name starts with the issue number, optionally after a prefix: `57-quiet-in-cities`, `claude/57-quiet-in-cities`. Each pull request gets a new branch.
3. Make the change, with a test in `spec/` for any behavior change.
4. Run `make check` locally.
5. Open the pull request as a **draft** and fill in the template, with `Closes #<issue>` for each spec it completes. Mark it ready for review when it is (see [Ready for review](#ready-for-review)). CI must pass and review conversations must be resolved before it can merge. The maintainer reviews outside pull requests. Their own get an automated review, because GitHub doesn't let authors approve their own pull requests, so `main` requires passing CI rather than an approval.
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
- **Changelog** entries are bullets, one per change, and end with the issues they come from: `(#27)`, or `(#27, #52)` for several. Notes about the whole release are bullets too and carry every issue that caused them. Text that isn't a bullet isn't checked. A repo test checks every entry under `### Unreleased`, and every entry of the released version once it's past 0.6.0. The release notes on CurseForge leave the tags out.
- **Releases:** the Release workflow creates the GitHub release for each tag. Its notes are that version's changelog section without the issue tags, the same notes CurseForge shows. The changelog's tags trace each entry to its issues, and squash-merge titles trace each commit to its pull request.

### Review loops

Pull requests written by Claude go through two review loops before the maintainer's review: a Lua architecture review, then a Lua testing review, each repeated until it approves. Every finding is fixed. Reviewers report only real problems, things that would actually go wrong for the addon, its players or its releases, and never invent issues or stretch for unrealistic edge cases to keep a loop going. "Everything is OK" is a perfectly good review when it's true. Claude runs them with the `lua-architect` and `lua-tester` agents in `.claude/agents/`, which point back here.

For a pull request that changes what players see, the Lua testing review also looks at its [UI simulator](#ui-simulator) screenshots and layout checks, and decides whether they're right. The maintainer doesn't review screenshots.

### Ready for review

A pull request is **ready for review** when all of these hold:

- CI is green on the latest commit;
- the description matches the final code;
- the branch is up to date with `main` and has no conflicts;
- for pull requests written by Claude: both of its review loops (Lua architecture, then Lua testing) have approved, with every finding fixed.

Then whoever drives it marks it ready (GitHub's **Ready for review** button, out of draft) and says so in a comment, so the maintainer never has to ask.

It is **ready to merge** when, on top of that, every review conversation is resolved.

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

  The environment keeps the installed tools for its later sessions. If the script fails, sessions don't start, and its log names the file and the host. A session that starts without the tools runs `make setup` itself.

CI also builds the zip with the BigWigs packager that releases use, and fails if its files differ from `make package`'s. If that check fails, add the new top-level file to `.pkgmeta`'s `ignore` list, or to the TOC if it should ship.

## UI simulator

The **UI simulator** workflow loads the packaged addon in [wow-ui-sim](https://github.com/Osso/wow-ui-sim), a headless WoW client that runs Blizzard's real UI code (#49). It runs on pull requests and on `main` whenever addon code, the TOC, the packaging or `uitests/` changes. It's report only: it never fails CI, and nothing it produces is trusted.

- **What it runs:**
  - **Lua errors** from loading, and the addon's frame tree.
  - **UI scenarios** in `uitests/scenarios.lua`, including the layout checks: text stays inside its frame, and frames stay on screen. Each layout check prints a `LAYOUT` line. The scenarios run in `run-tests`, then again at 1024 × 768 (the narrowest layout) and 1920 × 1080 (what most players use) through `dump-tree`, since `run-tests` has no size option (#148). Each `LAYOUT` line names its resolution.
  - **Screenshots** of the game screen, each options tab and page, the copy window and the buff-back button. Each options tab's shot is named after it, such as `options-buff-back.png` (#112). Every shot is taken at 1024 × 768 and again at 1920 × 1080, saved beside it as `<name>-1920x1080.png` (#148).
- **Where to look:** the run's summary has the errors, the scenarios and the layout lines. For a pull request from this repository, the screenshots are committed to the branch `ui-screenshots/pr-<number>`, replaced on every run. The branch is deleted when the pull request closes, merged or not, so look at the screenshots before then; the testing review already does, before the pull request is ready. To view them: `git fetch origin ui-screenshots/pr-<number>`, then open the PNGs, or browse the branch on GitHub.
- **Clean-up** (#106): the **UI screenshots clean-up** workflow deletes the branches.
  - **When a pull request closes,** it deletes that pull request's branch, if there is one. It never fails the pull request's checks.
  - **The sweep** deletes `ui-screenshots/pr-N` wherever pull request N is closed, and keeps every other branch. Run it now for the branches left from before the clean-up existed, such as `pr-88` and `pr-91`, and any time branches pile up (a simulator run that finishes after its pull request closes can publish its branch again). To run it: **Actions**, then **UI screenshots clean-up**, then **Run workflow**. Only the maintainer can: sessions can't delete branches.
  - **Safety:** both delete only branches named exactly `ui-screenshots/pr-<digits>`, so never `main` or a work branch. The close-time one builds the name only from the pull request's number. Neither checks out or runs anything from a pull request, and only those two jobs may write. A branch that's already gone is fine. `spec/repo_spec.lua` checks all of this.
- **What the screenshots show:** our text, layout and colours. Blizzard's art and WoW's fonts aren't there, so sizes are approximate. Layout checks catch the problem whatever the font. The final look is checked in game, on launch day (#50). Fetching Blizzard's art (level C) is the maintainer's call.
- **Adding a scenario:** write it in `uitests/scenarios.lua` with the simulator's `test()` and `assert*` functions, and add any new global it reads to `uitests/**` in `.luacheckrc`. Report lines go through `A_Print`, since Blizzard's UI sends `print` to chat. Put back anything a scenario changes, even when it fails. `uitests/` never ships. Anything that waits in game time belongs in `spec/`, whose client controls the clock.
- **Safety:** the simulator is unvetted code. Changes to the workflow keep every one of these, and `spec/repo_spec.lua` checks them:
  - the simulator built here from its source, pinned by commit, with the build and render images' bases pinned by digest. Never a published image or release binary. Read the source at a new commit before moving the pin, and post the review on the issue first (#154);
  - the simulator, and its build (which runs its build scripts and macros), in containers with no network, no capabilities and read-only sources. Only their output folders are writable. The one exception is the step that downloads its locked crates: `cargo fetch` has network, but runs none of their code;
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

Versions below 1.0.0 are pre-launch: 0.8.0 is the first file on CurseForge and 1.0.0 is the launch. A tag uploads as a normal release; the packager marks a file alpha or beta only when its tag contains that word, and the Release workflow accepts only a tag that is exactly `v` plus the TOC version. No beta route is set up yet.

Pull requests between releases add their `CHANGELOG.md` notes under a `### Unreleased` heading at the top; the release PR renames it to `## x.y.z`.

1. In a PR: bump `## Version` in `FriendlyForever.toc` and rename `### Unreleased` at the top of `CHANGELOG.md` to `## 0.8.0` (add notes there for anything missing). CurseForge shows only that section (`make release-notes` previews it).
2. After it merges, tag the merge commit and push the tag: `git tag v0.8.0 && git push origin v0.8.0`. Version tags can't be moved or deleted once pushed, so double-check the commit first. The GitHub release isn't made by hand: the workflow makes it in step 3.
3. The Release workflow's `verify` job checks that the tag is on `main` and matches the TOC, then runs lint and tests with no secrets. After that, the `release` job waits for your approval in the `release` environment, checks that the CurseForge project ID and key are set, and uploads. The packager uploads to CurseForge and creates the GitHub release for the tag, with the same notes and the zip attached. Once the job is green, there's nothing left to do.
