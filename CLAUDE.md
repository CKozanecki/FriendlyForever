# Working on Friendly Forever (for Claude)

**[CONTRIBUTING.md](CONTRIBUTING.md) is the source of truth.** Read it before your first change in a session and follow it as written, including:

- how changes land;
- specs and traceability;
- the review loops;
- ready for review.

Use the PR template too. This file only adds what applies to Claude sessions. Where the two seem to differ, CONTRIBUTING.md wins: fix this file.

## Starting and stopping

- **Continuing an issue:** read its latest handoff comment first and follow its working rules.
- **Stopping partway:** leave a handoff comment on the issue. Say what's done, where it lives (branch, commit, PR), what's left, and anything the next session must know.

## Pull requests

Don't skip these steps, which are easy to miss (#75 missed them):

- `Closes #<issue>` and the acceptance criteria checklist in the description;
- [marking the PR ready yourself](CONTRIBUTING.md#ready-for-review), with a comment, once every point holds.

**Another PR merged:** recheck every PR you've marked ready. Bring the branch up to date with `main`, wait for CI and update the description. Fix anything that no longer holds.

## Tests

- **Which tests:** write the test each acceptance criterion names: white, black or red (see [Specs and traceability](CONTRIBUTING.md#specs-and-traceability)).
- **Mutation checks:** before calling tests done, change each new line of code temporarily and confirm a test fails. Restore the file exactly afterwards.
- **`make check`:** run it after `git add`. The repo spec checks tracked files, so a new file has to be tracked before the check can see it.

## Out of scope

- **Something you find that isn't the issue's job:** file a new issue for it, with what you found and a proposed spec. Don't widen the PR you're on.
- **Launch checks:** anything that can only be checked once WoW Forever launches (spell IDs, role APIs and the like) goes on #50.
