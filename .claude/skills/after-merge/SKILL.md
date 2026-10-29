---
name: after-merge
description: What the driver of a ready Friendly Forever pull request does after the owner merges another PR into main - merge main in, resolve conflicts, make check, both review loops confirm, CI, update the description, announce ready again. Use when told that another PR has merged while yours is ready or in review.
---

# After a merge

The rule is CLAUDE.md's "Several sessions at once" → **After each merge**, and the review re-confirmation rule in its Reviews section. CONTRIBUTING.md's [Ready for review](../../../CONTRIBUTING.md#ready-for-review) is the bar to meet again. This skill is the procedure. Where it and those files differ, they win and this file is fixed.

Only the driver of a PR does this to it. If it isn't your PR, message its driver instead.

## When

When the owner (or the coordinator, relaying the owner) says a PR has merged. Sessions aren't told about merges, so don't poll for them.

## Steps

1. **Merge, don't rebase.** In your own worktree:
   ```
   git fetch origin main
   git merge origin/main
   ```
   Never force-push. (A branch that must be rebased is pushed under a new name, per CLAUDE.md.)
2. **Resolve conflicts** keeping both sides' intent: `-- Spec:` headers get both issue numbers, `### Unreleased` keeps both bullets. If both sides changed the same logic and either choice loses behaviour, ask the other PR's driver.
3. **`make check`** on the merged tree, after `git add` of anything new.
4. **Both review loops confirm the merge,** architecture then testing, using the `lua-architect` and `lua-tester` agents. Give them the merge commit's range (`<old head>..<merge commit>`) and say what conflicted. A clean merge still goes back to them, since the merged code can interact with yours (#85, #88, #93 recorded each confirmation).
5. **Push** (`git push -u origin <branch>`) and wait for CI to go green on the merge commit.
6. **Update the description:** the merge, what conflicted and how it was resolved, the reviewers' confirmations, any new test count, and the ready checklist.
7. **Announce ready again** with a comment on the PR, and send the coordinator a one-line notice if one is running.
