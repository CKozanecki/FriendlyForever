# Working on Friendly Forever (for Claude)

**[CONTRIBUTING.md](CONTRIBUTING.md) is the source of truth.** Read it before your first change in a session and follow it as written, including:

- how changes land;
- specs and traceability;
- the review loops;
- ready for review.

Use the PR template too. This file only adds what applies to Claude sessions. Where the two seem to differ, CONTRIBUTING.md wins: fix this file.

## Standards and safety

- **Standards:** work to enterprise standards, safety and security above all. Don't copy shortcuts from addons the project takes ideas from, such as Manners.
- **Casting:** nothing casts without a player's press, and only through secure buttons.
- **Input:** treat everything from the game, chat, addon messages, saved settings and pasted text as untrusted.
- **Secret values:** never compare or index one.
- **External code and tools:** don't run any until you've checked it's safe. The wow-ui-sim trial (#49, #53) is the model:
  - its image pinned by digest;
  - no network;
  - read-only mounts;
  - no secrets.
- **Secrets never pass through Claude.** The CurseForge key lives only in the `release` environment, as `CF_API_KEY`. Never ask for it, print it or commit it.
- **The owner merges.** Never merge, approve or delete branches. Ask before deleting anything. Leave stale branches for the owner, and say which they are.
- **Force-pushing:** never. Push a rebased branch under a new name and flag the old one for the owner to delete.

## Starting and stopping

- **Continuing an issue:** read its latest handoff comment first and follow its working rules.
- **Stopping partway:** leave a handoff comment on the issue. Say what's done, where it lives (branch, commit, PR), what's left, and anything the next session must know.

## Issues and specs

- **Duplicates:** search the backlog before filing an issue. #69 duplicated #41 and had to be merged back.
- **WoW Forever isn't Classic Era.** Check game facts against Forever sources (Wowhead's `/forever/` pages, patch notes) before writing a spec. Put the sources on the issue, and list anything unconfirmed as a launch check on #50. For example: Salvation isn't a Blessing on Forever, Revoke and Mass Salvation exist, and Blessings last an hour. If a cloud session can't reach wowhead.com, use web search and say so on the issue.
- **Product behaviour is the owner's call:** defaults, what's on or off, and how raids or battlegrounds behave. Ask them, and record the answer on the issue, as CONTRIBUTING.md asks for decisions. For example, the turn-on triggers default to on (#72), and "Start here" (#47) leads players to those settings.
- **Out of scope:** something you find that isn't the issue's job gets a new issue, with what you found and a proposed spec. Don't widen the PR you're on.
- **Launch checks:** anything that can only be checked once WoW Forever launches (spell IDs, role APIs and the like) goes on #50.

## Pull requests

- **Branches:** name each one `claude/<issue>-<what-it-does>`, and make a new one per PR from the latest `main`.
- **Easy to miss** (#75 missed both):
  - `Closes #<issue>` with the criteria checklist;
  - [marking the PR ready yourself](CONTRIBUTING.md#ready-for-review), with a comment.
- **Part of a spec:** say `Refs #<issue>`, list which acceptance criteria the PR covers, and name the parts still to come. Only the PR that completes the spec says `Closes`. #73 and #74 did this for #68.
- **Stacked work:** never open a PR on another PR's branch. Build on it locally if you need to. Once the first PR merges (as a squash), rebase onto `main` and open the PR from the rebased branch.

## Several sessions at once

- **Your own worktree:** other sessions share the main checkout and switch its branches. Work in a worktree of your own, never switch branches in the shared checkout, and remove your worktree when you're done.
- **One driver per PR:** only the session driving a PR pushes to its branch, updates its description or announces it ready. Anyone else sends that session a message.
- **Merge order:** when several PRs are ready, trial-merge every pair locally. Recommend an order to the owner, with the reasons and which pairs conflict. Note what you ran in the descriptions of your own PRs, and send it to the drivers of the others.
- **After each merge:** a session isn't told when the owner merges, so wait for the owner to say so; don't poll. Then the driver of each ready PR merges `main` into it and resolves any conflicts. Next comes `make check`, and both review loops confirm the merge (see Reviews). Then CI, an updated description, and the PR announced ready again.

## Reviews

- **Fix everything a review finds,** optional nits included.
- **Changes after an approval:** any change a review loop hasn't seen goes back to it for confirmation before the PR is called ready. That includes test-only and test-helper changes, merges that resolved conflicts, and rebases. On #72, a test-helper change made after the architecture approval hid a real bug, and the re-check caught it.
- **UI changes:** before the testing review, wait for the [UI simulator](CONTRIBUTING.md#ui-simulator) run, then tell the testing reviewer to fetch `ui-screenshots/pr-<number>`, view the screenshots, read the `LAYOUT` lines, and decide. Their verdict is the only look the screenshots get: the owner won't review them. Say in the PR what the reviewer saw.
- **Reviewer instructions:** tell each review agent:
  - the worktree path and the diff range to review;
  - that "everything is OK" is a valid answer;
  - to report only real defects, each with file:line and a concrete failure scenario;
  - to restore every mutation and leave `git status` clean;
  - to end with APPROVED or CHANGES REQUESTED.

## Tests

- **Which tests:** write the test each acceptance criterion names: white, black or red (see [Specs and traceability](CONTRIBUTING.md#specs-and-traceability)).
- **Chaos tests:** check invariants independently. Work them out from the simulated client's own state, never by calling the code under test. #73's testing review caught a chaos test that only checked the rules against themselves.
- **The simulated client** (`spec/support/wow.lua`):
  - New behaviour must be realistic. Document it in the ASSUMPTIONS block, with what to verify in game on #50.
  - When unsure, choose the pessimistic behaviour.
  - Test-wide defaults go in `wow.boot` with an opt-out, like `autoBuffMode`. Read the given saved settings before loading fills in defaults.
- **Mutation checks:** before calling tests done, change each new line of code temporarily and confirm a test fails. Restore the file exactly afterwards.
- **`make check`:**
  - **Every change:** docs, art and config too. An asset missing from `.pkgmeta`'s ignore list once broke the build on a no-code change.
  - **After `git add`:** the repo spec checks tracked files, so a new file has to be tracked before the check can see it.
