---
name: coordinator
description: Run several Claude sessions working on Friendly Forever for the owner - one driver per PR, relaying owner-facing notices, verifying "ready" PRs contain main, trial-merging and recommending a merge order, the after-merge round, archiving finished sessions, and a quiet 30-minute check-in. Use when a session is asked to coordinate or watch other sessions.
---

# Coordinator

How the owner's sessions were coordinated on 2026-10-28/29, when ten ran at once. The rules are CLAUDE.md's "Several sessions at once" and "The owner merges"; CONTRIBUTING.md is the source of truth for how changes land. This skill is the procedure. Where it and those files differ, they win and this file is fixed.

The tools are the remote-session ones: `list_sessions`, `get_session`, `list_events`, `send_message`, `archive_session` and `send_later` (or `create_trigger`).

## What the coordinator never does

- **Never merges, approves or deletes:** not a PR, a branch, an issue or a comment. The owner merges (CLAUDE.md). Stale branches are listed for the owner: only a branch still there after its PR merged or closed, or one with no PR. A merged PR's branch and its `ui-screenshots/pr-<n>` branch delete themselves, so they aren't listed (#119).
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
- **Before telling the owner something is pending, read that session's transcript** (`list_events` with `kinds: ["user", "assistant", "result"]`), not just its status. A status says idle; only the transcript says whether it's waiting on the owner, finished, or stuck, and whether the owner already answered.
- Relay to the owner in one short list: what's needed, from whom, with the link. Don't relay routine progress.

## A PR announced ready

1. **Verify it contains `main`:**
   ```
   git fetch origin main <branch>
   git merge-base --is-ancestor origin/main origin/<branch>
   ```
   If it doesn't, it isn't ready: tell its driver to merge `main` in (the `after-merge` skill), and don't report it to the owner yet.
2. Check CI is green on its head and its description's ready checklist is ticked.
3. When more than one PR is ready, **trial-merge every pair** and recommend an order (the `merge-order` skill) before reporting.

## After the owner merges a PR

**Spotting a merge.** The owner may say so, or may just merge on GitHub. So at every check-in, read each tracked PR's state (`gh api repos/CKozanecki/FriendlyForever/pulls/<n>`, read only). GitHub doesn't notify sessions of merges, and they don't poll (CLAUDE.md's "After each merge"); the coordinator tells them.

1. Tell the driver of each other ready PR to merge `main` in (the `after-merge` skill). Name the conflicts the trial merges predicted.
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
- **stay quiet when nothing changed:** no message to the owner, no comment anywhere. Just re-arm.

Stop the check-ins when the owner says so, or when no sessions are left running.
