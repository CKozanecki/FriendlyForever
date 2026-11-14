## What and why

<!-- What does this change, and what problem does it solve? -->

<!-- One keyword per spec issue this completes, e.g. "Closes #27, closes #52". -->
Closes #

### Acceptance criteria

<!-- Copy the issue's acceptance criteria here and tick them as they're met. -->
- [ ]

## How it was tested

- [ ] `make check` passes (lint, tests, package)
- [ ] Any safety-critical code (casting, secret values, saved settings) was mutation-checked: each new line changed, a test failed, the file restored. Say "none" if there is none ([what counts](https://github.com/CKozanecki/FriendlyForever/blob/main/CONTRIBUTING.md#review-loops))
- [ ] New or changed behavior has a test in `spec/`, and changed spec files name their issue (`-- Spec: #27`)
- [ ] Tried in game (say where: beta, stress test, live) and what was checked:

## Release

- [ ] User-visible change: added its note as `changes/<issue>.md`, one bullet ending with its issue(s), e.g. `(#123)` or `(#27, #52)` ([Changelog notes](https://github.com/CKozanecki/FriendlyForever/blob/main/CONTRIBUTING.md#changelog-notes)); `CHANGELOG.md` itself is changed only by a release PR
- [ ] No new globals, saved-variable fields or chat output that bypasses `ChatQueue`

## Ready for review

See [Ready for review](https://github.com/CKozanecki/FriendlyForever/blob/main/CONTRIBUTING.md#ready-for-review). Open as a draft; mark ready when all hold:

- [ ] CI is green on the latest commit
- [ ] This description matches the final code
- [ ] The branch is up to date with `main` and has no conflicts
- [ ] Written by an agent: both review loops approved, or the one review / CI only that CONTRIBUTING.md's Review loops allows for this PR; every finding fixed
- [ ] No open question for the owner: this description has no "decisions for the owner" section, and choices made by following the spec are stated as decisions taken

<!-- Written by Claude: the model that served each review loop's final verdict, with the effort as configured (`high`, passed in the Agent call), never a reviewer's own report of it (CLAUDE.md's Review records). A review served by another family than its agent names doesn't count: run it again, or flag it to the owner. -->
- Lua architecture review: model , effort
- Lua testing review: model , effort
