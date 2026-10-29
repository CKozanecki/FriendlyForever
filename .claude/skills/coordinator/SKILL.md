---
name: coordinator
description: Run several Claude sessions working on Friendly Forever for the owner - one driver per PR, relaying owner-facing notices, verifying "ready" PRs contain main, trial-merging and recommending a merge order, the after-merge round, archiving finished sessions, and a quiet 30-minute check-in. Use when a session is asked to coordinate or watch other sessions.
---

# Coordinator

How the owner's sessions were coordinated on 2026-10-28/29, when ten ran at once. The rules are CLAUDE.md's "Several sessions at once" and "The owner merges"; CONTRIBUTING.md is the source of truth for how changes land. This skill is the procedure. Where it and those files differ, they win and this file is fixed.

The tools are the remote-session ones: `list_sessions`, `get_session`, `list_events`, `send_message`, `archive_session` and `send_later` (or `create_trigger`).

## What the coordinator never does

- **Never merges, approves or deletes:** not a PR, a branch, an issue or a comment. The owner merges (CLAUDE.md). Stale branches are listed for the owner.
- **Never drives another session's PR:** it doesn't push to it, edit its description or announce it ready. It sends that PR's driver a message.
- **Never passes secrets on,** and never asks for one.

## Keeping track

For each session, keep: its issue, its branch and PR, who drives the PR (one driver per PR), and its state (working, waiting on the owner, ready, merged).

**One driver per PR.** If two sessions touch the same PR, tell the one that isn't driving to stop and send its changes to the driver.

## Notices for the owner

- Every session, when it stops to wait for the owner (a question, a decision, a PR marked ready, a blocker), sends the coordinator a one- or two-line notice: the issue, what it needs, and where.
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

The owner says so; sessions aren't told, so don't poll.
1. Tell the driver of each other ready PR to merge `main` in (the `after-merge` skill). Name the conflicts the trial merges predicted.
2. **Archive the merged PR's session** once its PR has merged and the session is idle (read its transcript first: it may still be filing a follow-up). Don't archive a session that is working or waiting on the owner.
3. Update the recommended order for what's left.

## The 30-minute check-in

Schedule a check-in every 30 minutes (`send_later`, re-armed each time). At each one:
- list the sessions and read the transcripts of any that changed;
- act on anything new: a notice, a PR newly ready, a session stuck or failed;
- **stay quiet when nothing changed:** no message to the owner, no comment anywhere. Just re-arm.

Stop the check-ins when the owner says so, or when no sessions are left running.
