# Agent facts: how the instruction files load

How Claude Code and Codex read this repo's instructions, so AGENTS.md and CLAUDE.md stay one set of rules (#186). The research behind them is on #183. Where this file and AGENTS.md differ, AGENTS.md wins and this file is fixed.

| Fact | What we do about it | Source |
|---|---|---|
| Codex reads `AGENTS.md` from the repo root down to its working folder. In each folder it looks for `AGENTS.override.md` before `AGENTS.md`. | One `AGENTS.md`, at the root. `spec/agents_spec.lua` fails if any `AGENTS.override.md` exists. | [AGENTS.md guide](https://developers.openai.com/codex/guides/agents-md), #183 |
| Codex reads at most `project_doc_max_bytes` of instructions in all, 32 KiB (32768 bytes) unless set, and cuts the rest off without a warning. | `spec/agents_spec.lua` fails if `AGENTS.md` is over 32768 bytes. CLAUDE.md doesn't count: Codex never reads it. | `DEFAULT_PROJECT_DOC_MAX_BYTES = 32 * 1024` in `codex-rs/config/src/config_toml.rs`, and `AGENTS_MD_MAX_BYTES` in `codex-rs/core/src/config/mod.rs`, openai/codex `main` on 2026-11-02 (https://github.com/openai/codex) |
| Claude Code loads `CLAUDE.md`, and a line `@AGENTS.md` in it imports that file. It never reads `AGENTS.override.md`. | CLAUDE.md imports `@AGENTS.md` and adds only Claude's own rules. `spec/agents_spec.lua` fails if the import goes, or if a "Standards and safety" heading from AGENTS.md appears again in CLAUDE.md. | [Claude Code memory](https://code.claude.com/docs/en/memory), #183 |
| Neither file ships: the packager leaves out every path in `.pkgmeta`'s ignore list. | `AGENTS.md` and `CLAUDE.md` are on the list; `spec/repo_spec.lua` checks it. | `.pkgmeta`, #186 |
