# Working on Friendly Forever (for agents)

**[CONTRIBUTING.md](CONTRIBUTING.md) is the source of truth.** Read it before your first change in a session and follow it as written, including:

- how changes land;
- specs and traceability;
- the review loops;
- ready for review.

Use the PR template too. This file holds the rules every agent session follows, whatever the product (#183, #186). Only Claude Code sessions work on this project now: **the Codex trial is paused** (the owner cancelled it on 2026-11-14, set aside and not planned; #183, and #188 and #189 are closed as not planned). The split below stays so a trial can restart without rework. It only adds what applies to agent sessions. Where the two seem to differ, CONTRIBUTING.md wins: fix this file.

**One source of rules.** Each product's own file adds only what is specific to it: [CLAUDE.md](CLAUDE.md) imports this file and adds Claude's agents, skills, session tools and model rules; a product that reads this file itself (Codex, if the trial restarts) would put its own notes in a short section of it. Never add an `AGENTS.override.md`: Codex reads it first, but Claude never does, so its rules would drift unseen. `spec/agents_spec.lua` fails if either happens ([`docs/agent-facts.md`](docs/agent-facts.md)).

## Start here

An orientation for a new session (#182). It points to the detail rather than repeating it; CONTRIBUTING.md stays the source of truth.

- **What it is:** Friendly Forever is a courtesy addon for World of Warcraft: Forever. It greets guildmates, thanks strangers who buff you, and offers a one-press button to buff them back ([README.md](README.md)).
- **Everyday commands** ([Local setup](CONTRIBUTING.md#local-setup)):
  - `make setup` installs the pinned toolchain;
  - `make check` runs lint, tests and the release zip;
  - `~/.cache/friendlyforever/lua51/bin/busted spec/<name>_spec.lua` runs one spec file;
  - the [UI simulator](CONTRIBUTING.md#ui-simulator) runs on GitHub, not locally: its screenshots land on `ui-screenshots/pr-<number>` ([`docs/ui-simulator.md`](docs/ui-simulator.md)).
- **The shape of the code:**
  - one Lua module per job at the top level, listed in `FriendlyForever.toc`; `Core.lua` wires saved settings, game events and slash commands to them;
  - rules decide, the button casts: modules such as `BuffRules.lua` and `Offers.lua` choose who and what, and only the secure button in `BuffButton.lua` casts, on the player's press, because the game lets an addon cast no other way (Standards and safety, below);
  - all chat goes through `ChatQueue.lua`, so cooldowns, lockdown and rate limits apply ([Ground rules](CONTRIBUTING.md#ground-rules-for-addon-code));
  - tests in `spec/` run against a simulated client, `spec/support/wow.lua` ([`docs/simulated-client.md`](docs/simulated-client.md)); `spec/repo_spec.lua` checks the workflows, the packaging and these instructions, and `spec/agents_spec.lua` checks that this file and CLAUDE.md don't drift.

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
- **Secrets never pass through an agent.** The CurseForge key lives only in the `release` environment, as `CF_API_KEY`. Never ask for it, print it or commit it.
- **The owner merges.** Never merge, approve or delete branches. Ask before deleting anything. Leave stale branches for the owner, and say which they are.
- **Merged branches:** GitHub deletes a PR's branch when it merges, and `ui-screenshots/pr-<n>` when PR n closes (#115), so don't list those (#119). A stale branch is one still there after its PR merged or closed, or one with no PR.
- **Force-pushing:** never. Push a rebased branch under a new name and flag the old one for the owner to delete.

## Shared knowledge

Facts sessions kept rediscovering, each with its source. Read the one you need before you research it again, and add to it in the PR that finds something new:

- [`docs/forever-facts.md`](docs/forever-facts.md): WoW Forever API and game facts the code depends on, and which are confirmed in game;
- [`docs/simulated-client.md`](docs/simulated-client.md): how `spec/support/wow.lua` models the game, and how to extend it;
- [`docs/ui-simulator.md`](docs/ui-simulator.md): the UI simulator's known quirks and workarounds (#100);
- [`docs/visual-style.md`](docs/visual-style.md): the colour palette, its contrast and colour-blindness numbers, and the scrolling rule (#46);
- [`docs/agent-facts.md`](docs/agent-facts.md): how Claude Code and Codex load these instructions, and Codex's size cap, kept for a restart (#186).

## Starting and stopping

- **Continuing an issue:** read its latest handoff comment first and follow its working rules.
- **Stopping partway:** leave a handoff comment on the issue. Say what's done, where it lives (branch, commit, PR), what's left, and anything the next session must know.
- **Handoff format** (#183), so every product can read every other's. Write it whenever you stop or finish an issue's work:

  ```
  ### Handoff · <product> <model as served> · <UTC time>
  - State: done | partial | blocked
  - Branch / commit / PR:
  - Done:
  - Left:
  - Next session must know:
  ```

## Issues and specs

- **Duplicates:** search the backlog before filing an issue. #69 duplicated #41 and had to be merged back.
- **WoW Forever isn't Classic Era.** Check game facts against Forever sources (Wowhead's `/forever/` pages, patch notes) before writing a spec. Put the sources on the issue, and put anything unconfirmed on a new issue labelled `quality`, with the source and how to check it in game. For example: Blizzard removed Salvation, Mass Salvation and Revoke right before launch (owner, 2026-11-08), and Blessings last an hour. If a cloud session can't reach wowhead.com, use web search and say so on the issue.
- **The owner's word about the game is a fact.** Record it as a fact, with the owner as the source. Never write "the owner believes", "on the owner's belief" or a similar hedge in player-facing text or docs. If a session doubts a statement, it checks the official patch notes first and tells the coordinator before writing anything public; it doesn't ask the owner to prove it and doesn't publish the doubt (#237).
- **Product behaviour is the owner's call:** defaults, what's on or off, and how raids or battlegrounds behave. Ask them, and record the answer on the issue, as CONTRIBUTING.md asks for decisions. For example, the turn-on triggers default to on (#72), and "Start here" (#47) leads players to those settings.
- **Out of scope:** something you find that isn't the issue's job gets a new issue, with what you found and a proposed spec. Don't widen the PR you're on.
- **Unconfirmed game facts:** the launch-day test pass is complete and its checks worked in game, except four IDs on #207 and the Salvation, Mass Salvation and Revoke checks, removed by Blizzard (#208) (#50, closed; #197). A game fact that can only be checked in game and isn't confirmed yet (spell IDs, role APIs and the like) goes on a new issue labelled `quality`, with the source and how to check it in game. Don't reopen #50.

## Pull requests

- **Branches:** name each one `claude/<issue>-<what-it-does>`. Make a new one per PR from the latest `main`.
- **Commit trailers:** each commit names the product that wrote it in its last lines, with a `Claude-Session: <session link>` trailer.
- **Easy to miss** (#75 missed the first two):
  - `Closes #<issue>` with the criteria checklist;
  - [marking the PR ready yourself](CONTRIBUTING.md#ready-for-review), with a comment;
  - a user-visible change's note as `changes/<issue>.md`, never a line in `CHANGELOG.md` ([Changelog notes](CONTRIBUTING.md#changelog-notes), #261).
- **No open question when ready** (#215): a PR with an open question for the owner is not ready. Ask first, and mark it ready only after the answer is applied (CONTRIBUTING.md's "Ready for review").
- **Merging and patch releases** (#241): a PR can merge once the required `check` is green; nobody waits for the report-only jobs. A patch release of documentation-only fixes is one PR with the fix (CONTRIBUTING.md's "How changes land" and "Releasing").
- **Part of a spec:** say `Refs #<issue>`, list which acceptance criteria the PR covers, and name the parts still to come. Only the PR that completes the spec says `Closes`. #73 and #74 did this for #68.
- **Stacked work:** never open a PR on another PR's branch. Build on it locally if you need to. Once the first PR merges (as a squash), rebase onto `main` and open the PR from the rebased branch.

## Several sessions at once

- **Your own worktree:** other sessions share the main checkout and switch its branches. Work in a worktree of your own, never switch branches in the shared checkout, and remove your worktree when you're done.
- **One driver per PR:** only the session driving a PR pushes to its branch, updates its description or announces it ready. Anyone else sends that session a message. Never push to a branch with another product's prefix.
- **Merge order:** when several PRs are ready, trial-merge every pair locally. Recommend an order to the owner, with the reasons and which pairs conflict. Note what you ran in the descriptions of your own PRs, and send it to the drivers of the others.
- **After each merge:** GitHub doesn't notify sessions of merges, so wait for the owner or the coordinator to say so; don't poll. The coordinator watches GitHub for merges and tells each PR's session (#172). Then the driver of each ready PR merges `main` into it and resolves any conflicts. Next comes `make check`, and the reviewers confirm the merge, unless it touches none of the PR's files (CONTRIBUTING.md's [Review loops](CONTRIBUTING.md#review-loops)). Then CI, an updated description, and the PR announced ready again. A ready PR that is only behind `main` (no shared file, no conflict) is not for the driver: the owner clicks Update branch (CONTRIBUTING.md's [Only behind `main`](CONTRIBUTING.md#only-behind-main), #229).

## Reviews

- **Fix everything a review finds,** optional nits included.
- **Reviewers share your worktree:** while a review agent is running, it temporarily changes files to check the tests catch it. Don't stage or commit then: `git add -A` on #46 picked up a reviewer's edit into a merge commit (807bc8e). Wait until it reports and `git status` is clean, or stage only the files you changed.
- **Changes after an approval:** any change a review loop hasn't seen goes back to it for confirmation before the PR is called ready. That includes test-only and test-helper changes, merges that resolved conflicts, and rebases. A merge that is clean and shares no file with the PR, a merge whose shared files' changed regions don't overlap (one combined pass), and a docs-only PR, need less review: CONTRIBUTING.md's [Review loops](CONTRIBUTING.md#review-loops). On #72, a test-helper change made after the architecture approval hid a real bug, and the re-check caught it. A merge confirmation mutates only the lines the merge changed or resolved, not the whole PR again.
- **UI changes:** before the testing review, wait for the [UI simulator](CONTRIBUTING.md#ui-simulator) run, then tell the testing reviewer to fetch `ui-screenshots/pr-<number>`, view the screenshots, read the `LAYOUT` lines, and decide. Their verdict is the only look the screenshots get: the owner won't review them. Say in the PR what the reviewer saw.
- **Who reviews:** every PR goes through both review loops (Lua architecture, then Lua testing) before it's marked ready, except where CONTRIBUTING.md's [Review loops](CONTRIBUTING.md#review-loops) allows less (a docs-only PR, a merge that shares no file). They run as Claude's reviewer agents (CLAUDE.md), in that order, except where CONTRIBUTING.md's [Review loops](CONTRIBUTING.md#review-loops) lets both run at once.
- **Keep them current:** when a review finds a lesson rather than a one-off (a bug class that can recur, or a check that would have caught it), the same PR adds it, citing the PR or issue, to the right reviewer agent's Lessons, or a fact to the right file in `docs/`.

## Tests

- **Toolchain:** `make setup` installs the pinned, checksummed tools (see [Local setup](CONTRIBUTING.md#local-setup)). If it can't, report the host it names; never install Lua, busted or luacheck another way.

- **Which tests:** write the test each acceptance criterion names: white, black or red (see [Specs and traceability](CONTRIBUTING.md#specs-and-traceability)).
- **Quick loops while coding:** run only the relevant specs (`make test SPECS="spec/a_spec.lua"`) and a few seeds of a chaos spec while you iterate. Then run the full `make check`, with every spec and every seed, before the reviews (#217). Never commit a spec with its seed list narrowed.
- **Chaos tests:** check invariants independently. Work them out from the simulated client's own state, never by calling the code under test. #73's testing review caught a chaos test that only checked the rules against themselves.
- **The simulated client** (`spec/support/wow.lua`):
  - New behaviour must be realistic. Document it in the ASSUMPTIONS block, with the new `quality` issue that says what to verify in game, if it isn't confirmed.
  - When unsure, choose the pessimistic behaviour.
  - Test-wide defaults go in `wow.boot` with an opt-out, like `autoBuffMode`. Read the given saved settings before loading fills in defaults.
- **Mutation checks:** for safety-critical code only (casting, secret values, saved settings: CONTRIBUTING.md's [Review loops](CONTRIBUTING.md#review-loops) says what counts), change each new or changed line of it temporarily before calling tests done, confirm a test fails, and list each mutation and its result in the PR (the reviewer checks the list and doesn't repeat it). Restore the file exactly afterwards. A merge confirmation mutates only the lines the merge changed or resolved.
- **`make check`:**
  - **Every change:** docs, art and config too. An asset missing from `.pkgmeta`'s ignore list once broke the build on a no-code change.
  - **After `git add`:** the repo spec checks tracked files, so a new file has to be tracked before the check can see it.
