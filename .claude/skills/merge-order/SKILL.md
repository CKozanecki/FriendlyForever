---
name: merge-order
description: Trial-merge every pair of ready Friendly Forever pull requests, then recommend a merge order to the owner with reasons and the conflicting pairs. Use when two or more PRs are ready (or about to be) and someone needs to know which to merge first.
---

# Merge order

The rule is CLAUDE.md's "Several sessions at once" → **Merge order**; CONTRIBUTING.md's [Ready for review](../../../CONTRIBUTING.md#ready-for-review) says what "ready" means. This skill is the procedure. Where it and those files differ, they win and this file is fixed.

Never merge, approve, push to another driver's branch or delete a branch. This is read-only work plus messages.

## 1. List the candidates

- Every open PR that is ready for review, plus any you drive that is about to be.
- For each, note its head commit and its driver (the session named in its description's footer or its ready comment).

## 2. Check each one contains `main`

```
git fetch origin main <branch> ...
git merge-base --is-ancestor origin/main origin/<branch> && echo "contains main"
```

A PR that doesn't contain the latest `main` isn't ready (CONTRIBUTING's "up to date with `main`"). Say so, and tell its driver to merge `main` in (the `after-merge` skill).

## 3. Trial-merge every pair

In your own worktree or with `git merge-tree`, never in the shared checkout:

```
git merge-tree --write-tree origin/<a> origin/<b>   # exit code 1 means a conflict
```

For each conflicting pair, record the files and what the conflict is. Common ones:
- `-- Spec:` headers on line 1 of the same spec file (#85/#87, #92/#93): keep both issue numbers.
- Bullets under `### Unreleased` in `CHANGELOG.md`: keep both.
- `spec/repo_spec.lua` and `CLAUDE.md`, which many PRs touch.

For a clean pair with overlapping files, say what overlaps, since a clean textual merge can still break (two PRs changing the same behaviour). Where practical, run `make check` on the merged tree of the pairs that overlap.

## 4. Recommend an order

Give the owner one list, with a reason for each place, for example:
- smaller or foundational PRs first (others build on them);
- a PR whose conflicts are trivial for the other side to resolve goes first;
- PRs that conflict with nothing can go in any order.

Name every conflicting pair and who resolves it (the driver of the PR that merges second).

## 5. Tell the drivers

- Note what you ran (heads, results) in the description of each PR you drive.
- Send each other driver one message with its results: its conflicts and the agreed resolution.
