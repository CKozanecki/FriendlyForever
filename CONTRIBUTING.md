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
- **Changelog** entries are bullets, one per change, and end with the issues they come from: `(#27)`, or `(#27, #52)` for several. Notes about the whole release are bullets too and carry every issue that caused them. Text that isn't a bullet isn't checked. A repo test checks every entry under `### Unreleased`, and every entry of the released version once it's past 1.6.0. The release notes on CurseForge leave the tags out.
- **Releases:** after tagging, the maintainer creates a GitHub release for the tag with **Generate release notes**, which lists the pull requests and the issues they closed.

### Review loops

Pull requests written by Claude go through two review loops before the maintainer's review: a Lua architecture review, then a Lua testing review, each repeated until it approves. Every finding is fixed. Reviewers report only real problems, things that would actually go wrong for the addon, its players or its releases, and never invent issues or stretch for unrealistic edge cases to keep a loop going. "Everything is OK" is a perfectly good review when it's true.

### Ready for review

A pull request is **ready for review** when all of these hold:

- CI is green on the latest commit;
- the description matches the final code;
- the branch is up to date with `main` and has no conflicts;
- for pull requests written by Claude: both of its review loops (Lua architecture, then Lua testing) have approved, with every finding fixed.

Then whoever drives it marks it ready (GitHub's **Ready for review** button, out of draft) and says so in a comment, so the maintainer never has to ask.

It is **ready to merge** when, on top of that, every review conversation is resolved.

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
2. After it merges, tag the merge commit and push the tag: `git tag v1.6.0 && git push origin v1.6.0`. Version tags can't be moved or deleted once pushed, so double-check the commit first. Then create a GitHub release for the tag with **Generate release notes**.
3. The Release workflow's `verify` job checks that the tag is on `main` and matches the TOC, then runs lint and tests with no secrets. After that, the `release` job waits for your approval in the `release` environment, checks that the CurseForge project ID and key are set, and uploads.
