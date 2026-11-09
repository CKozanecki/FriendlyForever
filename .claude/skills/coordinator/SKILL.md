---
name: coordinator
model: opus
description: Run several Claude sessions working on Friendly Forever for the owner - one driver per PR, relaying owner-facing notices, verifying "ready" PRs contain main, trial-merging and recommending a merge order, the after-merge round, archiving finished sessions, and a quiet 30-minute check-in. Use when a session is asked to coordinate or watch other sessions.
---

# Coordinator

How the owner's sessions were coordinated on 2026-10-28/29, when ten ran at once. The rules are AGENTS.md's "Several sessions at once" and "The owner merges", and CLAUDE.md's "Coordinating sessions"; CONTRIBUTING.md is the source of truth for how changes land. This skill is the procedure. Where it and those files differ, they win and this file is fixed.

The tools are the remote-session ones: `list_sessions`, `get_session`, `list_events`, `send_message`, `archive_session` and `send_later` (or `create_trigger`).

## What the coordinator never does

- **Never merges, approves or deletes:** not a PR, a branch, an issue or a comment. The owner merges (AGENTS.md). Stale branches are listed for the owner: only a branch still there after its PR merged or closed, or one with no PR. A merged PR's branch and its `ui-screenshots/pr-<n>` branch delete themselves, so they aren't listed (#119).
- **Never drives another session's PR:** it doesn't push to it, edit its description or announce it ready. It sends that PR's driver a message.
- **Never passes secrets on,** and never asks for one.

## Keeping track

For each session, keep: its issue, its branch and PR, who drives the PR (one driver per PR), and its state (working, waiting on the owner, ready, merged).

**One driver per PR.** If two sessions touch the same PR, tell the one that isn't driving to stop and send its changes to the driver.

## Notices for the owner

- Every session sends the coordinator a one- or two-line notice (the issue, the PR link, what's needed) the moment one of these happens, without being asked (CLAUDE.md's "Tell the coordinator"):
  - a PR is marked ready, or ready again after a merge of `main`;
  - it needs the owner: a question (one asked in its own session too), a decision or a blocker;
  - it's done: its PR merged and nothing is left;
  - something failed that it can't fix.

  A notice wakes the coordinator at once, so the owner hears without waiting for the check-in. When you start a session, give it your session ID and this rule.
- **Starting a session:** pass the `model` parameter on every session, set explicitly from CLAUDE.md's Models and effort table, never left to the session default: `sonnet` for a developer, `opus` for security-sensitive and release-workflow changes, specs and hard bugs (with effort `high`). The opening prompt names the model, and the effort where the table gives one. Never a dated model ID. Check the plan's usage first (CLAUDE.md's Plan limits): a fan-out is long work.
- **Before telling the owner something is pending, read that session's transcript** (`list_events` with `kinds: ["user", "assistant", "result"]`), not just its status. A status says idle; only the transcript says whether it's waiting on the owner, finished, or stuck, and whether the owner already answered.
- Relay to the owner in one short list: what's needed, from whom, with the link. Don't relay routine progress.
- **Questions come first.** Put every question for the owner at the top of the report, one per line, before any list of PRs (#215).

## A PR announced ready

1. **Verify it contains `main`:**
   ```
   git fetch origin main <branch>
   git merge-base --is-ancestor origin/main origin/<branch>
   ```
   If it doesn't, it isn't ready: tell its driver to merge `main` in (the `after-merge` skill), and don't report it to the owner yet.
2. Check CI is green on its head and its description's ready checklist is ticked.
   After a merge of `main`, check the description's two file lists too (CONTRIBUTING.md's [Review loops](../../CONTRIBUTING.md#review-loops)): if you can't confirm that `git diff --name-only <old main>..<new main>` and `git diff --name-only origin/main...HEAD` share no file and the merge was clean, the reviewers must have confirmed it.
3. Check there is no open owner question on it: none in its description, and none in its session's transcript that the owner hasn't answered. If there is one, it isn't ready to merge (CONTRIBUTING.md's "Ready for review", #215): tell its driver to wait for the answer, and put the question in the report.
4. When more than one PR is ready, **trial-merge every pair** and recommend an order (the `merge-order` skill) before reporting.

## After the owner merges a PR

**Spotting a merge.** The owner may say so, or may just merge on GitHub. So at every check-in, read each tracked PR's state (`gh api repos/CKozanecki/FriendlyForever/pulls/<n>`, read only). GitHub doesn't notify sessions of merges, and they don't poll (AGENTS.md's "After each merge"); the coordinator tells them.

1. For each other ready PR, compare the merge's files with the PR's files and the trial merge's conflicts, then tell the owner, naming the PR, "update branch only" or "developer must merge" (CONTRIBUTING.md's [Only behind `main`](../../CONTRIBUTING.md#only-behind-main), #229). Only for "developer must merge", tell its driver to merge `main` in (the `after-merge` skill). Name the conflicts the trial merges predicted, and the files the merge changes, so each driver can prove the merge is file-disjoint (CONTRIBUTING.md's [Review loops](../../CONTRIBUTING.md#review-loops)).
2. **Tell the merged PR's session at once, politely** (the owner's standing rule, #172). Don't wait for it to notice. First check whether anything is left for it: the PR says `Refs #<issue>` rather than `Closes`, or its transcript shows more parts of the spec still to come.
   - **Nothing left:** "Your PR #<n> merged. Your work is done: finish per CLAUDE.md's "Finishing" (a closing comment only if one is owed, the done line to me, remove your worktree, cancel check-ins, closing summary)."
   - **Work left:** "Your PR #<n> merged. Carry on with what's left on #<issue>." It keeps working, so don't archive it.

   Relay any owner step or stale branch it names; don't list the merged PR's own branch.
3. **Archive that session only after its closing summary,** once it's idle. Read its transcript first, not just its status. Never archive a session that is working or waiting on the owner.
   - **Not finished by the next check-in:** send one reminder. If it's still stuck at the one after, tell the owner instead of archiving.
4. Update the recommended order for what's left.

**A PR closed without merging:** read the session's transcript first. If it replaced the PR (a rebased branch under a new name, or a new PR), track the new one and say nothing. If the owner closed it and nothing replaces it, tell the session: "Your PR #<n> was closed without merging. If nothing is left, finish per CLAUDE.md's "Finishing"; otherwise tell me what's left." **When the owner says a session is done,** send the close-out above. **Every session you start** is told this in its opening prompt: when the coordinator says its work is done, it finishes and stops.

## The 30-minute check-in

Schedule a check-in every 30 minutes (`send_later`, re-armed each time). At each one:
- list the sessions and read the transcripts of any that changed;
- read each tracked PR's state on GitHub, and run "After the owner merges a PR" for any that merged or closed;
- archive every finished session whose closing summary is in;
- act on anything new: a notice, a PR newly ready, a session stuck or failed;
- **compare models** for each session you watch: `get_session`'s `configured_model` against `session_context.model` and `external_metadata.last_served_model` (normalize aliases and context-window suffixes first), and read `list_events` for fallback notices. Include your own session: it must be served by `opus`, because this skill's `model:` covers only the turn it loads in. Report any session served by another family to the owner, with what it was doing; a review it served doesn't count (CLAUDE.md's Models and effort);
- **check the plan's usage,** if you can see it. When it's low (past CLAUDE.md's 80% gate, or near the 3% reserve), put what's left in the check-in, even if nothing else changed. Give an OK past the gate only as Plan limits allows; otherwise ask the owner;
- **stay quiet when nothing changed** and usage isn't low: no message to the owner, no comment anywhere. Just re-arm.

Stop the check-ins when the owner says so, or when no sessions are left running.
