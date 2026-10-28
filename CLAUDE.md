# Working on Friendly Forever (for Claude)

**[CONTRIBUTING.md](CONTRIBUTING.md) is the source of truth.** Read it before your first change in a session and follow it as written, including:

- how changes land;
- specs and traceability;
- the review loops;
- ready for review.

This file only adds what applies to Claude sessions. Where the two seem to differ, CONTRIBUTING.md wins: fix this file.

## Starting and stopping

- **Continuing an issue:** read its latest handoff comment first and follow its working rules. Decisions and changes of scope go on the issue, not only in chat.
- **Stopping partway:** leave a handoff comment on the issue. Say what's done, where it lives (branch, commit, PR), what's left, and anything the next session must know.

## Pull requests

- **Branch:** start a new, meaningfully named branch from the latest `main` for every PR. CONTRIBUTING.md has the naming convention.
- **Description:** fill in the PR template:
  - `Closes #<issue>` for each spec the PR completes;
  - the issue's acceptance criteria as a checklist, ticked as they're met.
- **Draft:** open it as a draft.
- **Reviews:** run both review loops: Lua architecture first, then Lua testing. Re-run each until it approves, and fix every finding. Reviewers report only real problems and never invent issues.
- **Ready:** when every point in [Ready for review](CONTRIBUTING.md#ready-for-review) holds, mark it ready yourself and say so in a PR comment. Don't wait to be asked.
- **Another PR merged:** recheck every PR you've marked ready. Bring the branch up to date with `main`, wait for CI and update the description. Fix anything that no longer holds.

## Tests

- **Every change:** white, black and red (chaos) tests, as the acceptance criteria say.
- **Mutation checks:** before calling tests done, change each new line of code temporarily and confirm a test fails. Restore the file exactly afterwards.
- **`make check`:** run it after `git add`. The repo spec checks tracked files, so a new file has to be tracked before the check can see it.
- **New top-level files:** add them to `.pkgmeta`'s `ignore` list unless they ship.

## Out of scope

- **Something you find that isn't the issue's job:** file a new issue for it, with what you found and a proposed spec. Don't widen the PR you're on.
- **Launch checks:** anything that can only be checked once WoW Forever launches (spell IDs, role APIs and the like) goes on #50.
