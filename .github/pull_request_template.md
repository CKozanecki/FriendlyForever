## What and why

<!-- What does this change, and what problem does it solve? -->

<!-- One keyword per spec issue this completes, e.g. "Closes #27, closes #52". -->
Closes #

### Acceptance criteria

<!-- Copy the issue's acceptance criteria here and tick them as they're met. -->
- [ ]

## How it was tested

- [ ] `make check` passes (lint, tests, package)
- [ ] New or changed behavior has a test in `spec/`, and changed spec files name their issue (`-- Spec: #27`)
- [ ] Tried in game (say where: beta, stress test, live) and what was checked:

## Release

- [ ] User-visible change: added a line under `### Unreleased` in `CHANGELOG.md`, ending with its issue(s), e.g. `(#123)` or `(#27, #52)`
- [ ] No new globals, saved-variable fields or chat output that bypasses `ChatQueue`

## Ready for review

See [Ready for review](https://github.com/CKozanecki/FriendlyForever/blob/main/CONTRIBUTING.md#ready-for-review). Open as a draft; mark ready when all hold:

- [ ] CI is green on the latest commit
- [ ] This description matches the final code
- [ ] The branch is up to date with `main` and has no conflicts
- [ ] Written by an agent (Claude or Codex): both review loops approved, every finding fixed

<!-- Written by Claude: the model that served each review loop's final verdict, with its effort (CLAUDE.md's Models and effort). A review served by another family than its agent names doesn't count: run it again, or flag it to the owner. -->
- Lua architecture review: model , effort
- Lua testing review: model , effort
