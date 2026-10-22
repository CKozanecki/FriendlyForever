# Contributing

Ideas, bug reports and pull requests are welcome. Open an issue first for anything bigger than a small fix, so we can agree on the approach before you write it.

## How changes land

`main` is protected: every change, the maintainer's own included, goes through a pull request.

1. Branch from `main` (`fix/buff-thanks-in-raid`, `feat/new-greeting`).
2. Make the change, with a test in `spec/` for any behavior change.
3. Run `make check` locally.
4. Open a pull request and fill in the template. CI must pass, and the change is reviewed before it's merged.
5. Merges are squash merges, so each PR becomes one commit on `main`.

## Local setup

You need Python 3 and `zip`. Everything else installs into `~/.cache/friendlyforever`:

```
make setup   # Lua 5.1, busted, luacheck (once)
make check   # lint, tests, release zip
```

## Ground rules for addon code

- WoW runs Lua 5.1. Don't create globals: `.luacheckrc` lists the only ones allowed, and the lint fails on anything else.
- All chat output goes through `ChatQueue` so cooldowns, lockdown and rate limits apply.
- Never change a player's game settings (CVars) without them clicking something.
- Keep saved variables backward compatible. Old `FriendlyForeverDB` contents must still load.

## Releasing (maintainer)

1. In a PR: bump `## Version` in `FriendlyForever.toc` and add the release notes at the top of `CHANGELOG.md`.
2. After it merges, tag the merge commit and push the tag: `git tag v1.6.0 && git push origin v1.6.0`.
3. The Release workflow checks the tag is on `main` and matches the TOC, runs the tests, and uploads to CurseForge once the `release` environment is approved.
