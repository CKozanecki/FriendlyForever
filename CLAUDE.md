# Working on Friendly Forever (for Claude)

The rules every agent session follows, whatever the product, are in AGENTS.md, imported here:

@AGENTS.md

**[CONTRIBUTING.md](CONTRIBUTING.md) is the source of truth,** then AGENTS.md. This file adds only what is specific to Claude Code sessions: the reviewer agents and skills, the remote-session tools, plan limits and model choice. Where it seems to differ from either, they win: fix this file. Never repeat a shared rule here; `spec/agents_spec.lua` fails if a heading from AGENTS.md's "Standards and safety" appears in this file (#186).

## Agents and skills

- **Reviewer agents:** run the architecture review with the `lua-architect` agent and the testing review with the `lua-tester` agent ([`.claude/agents/`](.claude/agents/)). Their files hold the scope, the output format and the lessons of past reviews. Tell each one:
  - the worktree path and the diff range to review;
  - that "everything is OK" is a valid answer;
  - to report only real defects, each with file:line and a concrete failure scenario;
  - to restore every mutation and leave `git status` clean;
  - to end with APPROVED or CHANGES REQUESTED.
- **Launching a reviewer:** pass `effort: high` in the Agent call, along with `subagent_type`. The agent file's `effort: high` frontmatter should apply on its own, but the per-call parameter overrides it and is the explicit, documented way (Claude Code v2.1.292 or later); only the `CLAUDE_CODE_EFFORT_LEVEL` environment variable beats both. Never pass a lower level (#318).
- **Skills:** procedures are skills in [`.claude/skills/`](.claude/skills/): `after-merge`, `merge-order` and `coordinator` (running several sessions for the owner). They carry out the rules in AGENTS.md's "Several sessions at once" and "Coordinating sessions" below; where they differ, those rules win. A PR that is only behind `main` needs no merge from them: its driver updates the branch (CONTRIBUTING.md's [Only behind `main`](CONTRIBUTING.md#only-behind-main), #345).
- **Merging your PR** (a trial, #345), your own PR only. When it is only behind `main`, update it with the GitHub tool `update_pull_request_branch`, giving `expectedHeadSha`, and wait for `check` on the new head. Then, only once every stop in CONTRIBUTING.md's [Who merges](CONTRIBUTING.md#who-merges) holds:
  - **auto-merge:** turn it on with `enable_pr_auto_merge`, `mergeMethod: SQUASH`;
  - **already clean:** if that tool refuses because the PR can already merge, call `merge_pull_request` with `merge_method: squash` and `expectedHeadSha` set to the head you checked the stops on;
  - **anything else:** if a report-only job is the only one pending, or your permission check blocks the merge, don't find another way: tell the coordinator, which merges it.
- **Knowledge files:** AGENTS.md's "Shared knowledge" lists them: [`docs/forever-facts.md`](docs/forever-facts.md), [`docs/simulated-client.md`](docs/simulated-client.md), [`docs/ui-simulator.md`](docs/ui-simulator.md), [`docs/visual-style.md`](docs/visual-style.md) and [`docs/agent-facts.md`](docs/agent-facts.md).

## Coordinating sessions

Claude sessions reach each other with the remote-session tools (`send_message` and the like).

- **Tell the coordinator:** when a coordinating session is running, send it one or two lines (the issue, the PR link, what's needed) the moment one of these happens, without waiting to be asked:
  - a PR is marked ready, or ready again after a merge of `main`;
  - you turned on auto-merge or merged your PR, or it needs the coordinator to merge it (say why);
  - you need the owner: a question (one you ask in your own session too), a decision or a blocker. Ask before you mark the PR ready: it waits for the answer (#215);
  - you're done: your PR merged and nothing is left;
  - something failed that you can't fix.

  Its check-in is only a safety net, so don't wait for it. Don't message for routine progress.
- **Finishing:** once your PR has merged and nothing is left on your issue, or the coordinator tells you your work is done, finish on your own. Don't ask the owner what's next or wait for a suggestion.
  1. Leave a closing comment on the issue only if AGENTS.md or this file asks for one: a handoff.
  2. Send the coordinator one line: `done: #<issue>, PR #<n> merged`, plus any step the owner still has to take (such as applying environment settings or running a workflow) and any stale branch.
  3. Remove your worktree, cancel any check-ins you scheduled, and end your turn with a short summary saying the work is complete and the session can be archived. Ask no questions.

## Plan limits

The owner's decisions are on #182 (2026-11-01).

- **Check first:** before long work (a review loop, a fan-out of sessions, a simulator run), check how much of the weekly plan's usage is left, if you can see it. If you can't, say so in your session.
- **The gate is 80%.** Past 80% of the weekly plan, long work needs the owner's explicit OK, recorded on the issue. The OK covers that piece of work only, and ends with the session or at a time the owner names.
- **The coordinator's OK:** the coordinator may give that OK for the owner only when it expects all the remaining work to go over the gate by 2% of the plan at most. If it can't be sure of that, the owner decides.
- **The reserve:** leave about 3% of the weekly plan for scheduled tasks; don't plan work into it.
- **The only sure stop is the account's spending limit.** These rules hold only while a session is checking, and a session past the gate in mid-turn won't notice. The owner sets that limit; Claude never changes it.

## Models and effort

Name the model by its family alias: `haiku`, `sonnet`, `opus` or `fable`. An alias picks the latest model in that family, so it stays current but never crosses into another family: `opus` can't quietly become Sonnet or Fable. Words like "fastest" or "most capable" describe a family; they never replace its name. Never write a dated model ID. Set the alias with `model:` and the effort with `effort:` in agent and skill frontmatter, and with the `model` parameter of Agent and session calls.

| Job | Family | Effort |
| --- | --- | --- |
| Lookups, searches and routine checks | `haiku` | `low` |
| Developer sessions: building and fixing | `sonnet` | session default |
| Developer sessions on security-sensitive and release-workflow changes, specs and hard bugs | `opus` | `high` |
| The coordinator (`coordinator` skill) | `opus` | session default |
| The architecture and testing reviews (`lua-architect`, `lua-tester`) | `opus` | `high` |

These are the owner's choices on #182 (reviewers and lookups 2026-11-01, developers and coordinator 2026-11-09). The Claude side is decided; the Codex trial (#183) is paused and doesn't hold it up. The owner hasn't set an effort for developers or the coordinator, so those cells say "session default" and the sessions keep it. **The coordinator sets `model` explicitly on every session it starts** and doesn't rely on the session default. Each reviewer agent names its family and effort in its frontmatter, and the `coordinator` skill names its family; the repo spec checks them against this table. `after-merge` and `merge-order` set no `model:`: a skill's `model:` switches the running session for the rest of that turn, and these run inside developer sessions and the coordinator, so they stay on whichever family that session has. The same limit applies to the `coordinator` skill: its `model: opus` covers only the turn it loads in, so **the coordinator session itself is started on `opus`** (the `model` parameter, or `/model opus`), and its check-ins compare its own served family too.

- **Record what served.** A session can be moved to another model mid-turn (overload or unavailability) even when its setting is right. `get_session` keeps the configured model (`configured_model`), the current setting (`session_context.model`) and the one that served the last turn (`external_metadata.last_served_model`), and `list_events` logs the fallbacks.
- **A review served by the wrong family doesn't count.** Run it again on the family its agent names, or flag it to the owner.

## Review records

AGENTS.md's Reviews section holds the review rules; this adds Claude's record of them.

- **Which model reviewed:** each verdict names the model that served it, its family, just above the verdict line. Check that against the family its agent names (Models and effort) before you count it, and list each review loop's model and effort in the PR description.
- **Effort is recorded as configured, not as reported (#318).** A reviewer can't reliably see its own effort: on 2026-11-13 a reviewer launched with an explicit `effort: high` still saw only `reasoning_effort: 15`, the same as one launched without it. So the PR records the effort you configured (the frontmatter's `high`, plus the Agent call's `effort` parameter), and never a number or level a reviewer reports about itself. Say plainly in the PR that the served effort isn't exposed to the session. If the platform later exposes it (`get_session` and `list_events` do for sessions, not for subagents), record that too. The owner decided on #318 (2026-11-14): a review counts when it was launched on its agent's family with `effort: high` configured, whatever effort the reviewer reports; past reviews that reported a lower or unconfirmed effort count too. Re-run a review only when it was demonstrably launched without `high` configured.
