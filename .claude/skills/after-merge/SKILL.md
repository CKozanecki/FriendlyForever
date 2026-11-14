---
name: after-merge
description: What the driver of a ready Friendly Forever pull request does after the owner merges another PR into main - merge main in, resolve conflicts, make check, reviewers confirm unless the merge shares no file with the PR, CI, update the description, announce ready again. Use when told that another PR has merged while yours is ready or in review.
---

# After a merge

The rule is AGENTS.md's "Several sessions at once" → **After each merge**, and the review re-confirmation rule in its Reviews section. CONTRIBUTING.md's [Ready for review](../../../CONTRIBUTING.md#ready-for-review) is the bar to meet again. This skill is the procedure. Where it and those files differ, they win and this file is fixed.

Only the driver of a PR does this to it. If it isn't your PR, message its driver instead.

## When

When the owner or the coordinator says a PR has merged. GitHub doesn't notify sessions of merges, and the coordinator watches for them (#172), so don't poll for them yourself.

Only for a PR that needs a developer. If the PR shares no file with the merge and has no conflict, don't merge: update the branch and put both file lists in the description (CONTRIBUTING.md's [Only behind `main`](../../../CONTRIBUTING.md#only-behind-main), #345).

## Steps

0. **Auto-merge off first.** If your PR has auto-merge on, turn it off (`disable_pr_auto_merge`), so it can't merge before the reviewers have confirmed the merge (CONTRIBUTING.md's [Who merges](../../../CONTRIBUTING.md#who-merges): off before any push but Update branch).
1. **Merge, don't rebase.** In your own worktree:
   ```
   git fetch origin main
   git merge origin/main
   ```
   Never force-push. (A branch that must be rebased is pushed under a new name, per AGENTS.md.)
2. **Resolve conflicts** keeping both sides' intent: `-- Spec:` headers get both issue numbers. If the PR still has a line under `### Unreleased`, move it to a fragment now (CONTRIBUTING.md's [Changelog notes](../../../CONTRIBUTING.md#changelog-notes)); fragments never conflict. If both sides changed the same logic and either choice loses behaviour, ask the other PR's driver.
3. **`make check`** on the merged tree, after `git add` of anything new.
4. **Prove whether the merge is file-disjoint** (CONTRIBUTING.md's [Review loops](../../../CONTRIBUTING.md#review-loops)). Before step 1, save `git diff --name-only origin/main...HEAD` (the PR's files). After it, run `git diff --name-only <old main>..<new main>`. If step 2 had no conflicts and no file is in both lists, run `make check`, confirm CI is green, put both lists in the description and skip to step 5: the reviewers don't confirm.
   If a file is in both lists, or a conflict was resolved, the reviewers confirm the merge and the resolution only: architecture then testing, using the `lua-architect` and `lua-tester` agents. If the merge was clean and, in every shared file, the hunks each side changed don't overlap (check with `git diff` of that file on both sides), one combined pass confirms it instead (the two agent files run as one); overlapping hunks or a resolved conflict keep both loops. Give them the merge commit's range (`<old head>..<merge commit>`) and say what conflicted. The testing reviewer mutates only the lines the merge changed or resolved, not the PR's earlier list. Where a file overlaps, a clean merge still goes back to them, since the merged code can interact with yours (#85, #88, #93 recorded each confirmation).
5. **Push** (`git push -u origin <branch>`) and wait for CI to go green on the merge commit.
6. **Update the description:** the merge, what conflicted and how it was resolved, both file lists or the reviewers' confirmations, any new test count, and the ready checklist.
7. **Announce ready again** with a comment on the PR, and send the coordinator a one-line notice if one is running.
8. **Merge:** once every stop in CONTRIBUTING.md's [Who merges](../../../CONTRIBUTING.md#who-merges) holds, turn auto-merge on again, or merge as CLAUDE.md's "Merging your PR" says.
