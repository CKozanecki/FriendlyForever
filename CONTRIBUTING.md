# Contributing

Ideas, bug reports and pull requests are welcome. Open an issue first for anything bigger than a small fix, so we can agree on the approach before you write it.

## How changes land

`main` is protected: every change, the maintainer's own included, goes through a pull request.

1. Start from an issue (see [Specs and traceability](#specs-and-traceability)).
2. Branch from the latest `main`, naming the issue: `<issue>-<short-name>` (`57-quiet-in-cities`). Each pull request gets a new branch.
3. Make the change, with a test in `spec/` for any behavior change.
4. Run `make check` locally.
5. Open a pull request and fill in the template, with `Closes #<issue>` for each spec it completes. CI must pass and review conversations must be resolved before it can merge. The maintainer reviews outside pull requests. Their own get an automated review, because GitHub doesn't let authors approve their own pull requests, so `main` requires passing CI rather than an approval.
6. Merges are squash merges, so each PR becomes one commit on `main`.

## Specs and traceability

Every change can be traced from its spec to its code, tests, pull request and release.

- **Specs are issues.** A feature or fix starts as an issue with a **Spec** and testable **Acceptance criteria**. Each phase of work is a parent issue, and its features are sub-issues. Decisions and changes of scope are written on the issue, not left in chat.
- **Acceptance criteria name their tests.** Each criterion says which kind of test proves it:
  - **white:** expected use gives the expected result;
  - **black:** bad or error input is handled correctly;
  - **red:** chaos (random storms, damaged state) never crashes the addon, and anything damaged heals itself.
- **Pull requests** say `Closes #<issue>` for each spec they complete and tick the criteria they meet.
- **Tests:** each spec file names the issues it covers at the top, and test names repeat the acceptance criteria in words.
- **Changelog** entries end with the issue they come from, as in `(#27)`. A repo test checks every entry under `### Unreleased`.
- **Releases:** the GitHub release lists the issues closed since the last tag.

### Ready for review

A pull request is ready for review when all of these hold:

- CI is green on the latest commit;
- the reviews it needs have approved and every finding is fixed;
- the description matches the final code;
- the branch is up to date with `main` and has no conflicts.

Whoever drives the pull request says so in it ("ready for review") at that moment, so the reviewer never has to ask.

## Local setup

You need Python 3 and `zip`. Everything else installs into `~/.cache/friendlyforever`:

```
make setup   # Lua 5.1, busted, luacheck (once)
make check   # lint, tests, release zip
```

CI also builds the zip with the BigWigs packager that releases use, and fails if its files differ from `make package`'s. If that check fails, add the new top-level file to `.pkgmeta`'s `ignore` list, or to the TOC if it should ship.

## Ground rules for addon code

- WoW runs Lua 5.1. Don't create globals: `.luacheckrc` lists the only ones allowed, and the lint fails on anything else.
- All chat output goes through `ChatQueue` so cooldowns, lockdown and rate limits apply. The one exception is the buff-back button's optional line: it is part of the button's macro and said by the player's own press, so it checks the same rules (snooze, AFK) when the macro is built instead.
- Never change a player's game settings (CVars) without an explicit action from them (a click, or `/friendly nameplates`).
- Keep saved variables backward compatible. Old `FriendlyForeverDB` contents must still load.

## Releasing (maintainer)

Pull requests between releases add their `CHANGELOG.md` notes under a `### Unreleased` heading at the top; the release PR renames it to `## x.y.z`.

1. In a PR: bump `## Version` in `FriendlyForever.toc` and rename `### Unreleased` at the top of `CHANGELOG.md` to `## 1.6.0` (add notes there for anything missing). CurseForge shows only that section (`make release-notes` previews it).
2. After it merges, tag the merge commit and push the tag: `git tag v1.6.0 && git push origin v1.6.0`. Version tags can't be moved or deleted once pushed, so double-check the commit first.
3. The Release workflow's `verify` job checks that the tag is on `main` and matches the TOC, then runs lint and tests with no secrets. After that, the `release` job waits for your approval in the `release` environment, checks that the CurseForge project ID and key are set, and uploads.
