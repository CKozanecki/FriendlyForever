#!/usr/bin/env bash
# Writes RELEASE_NOTES.md with only the newest version's section of
# CHANGELOG.md, so each CurseForge file shows its own notes rather than the
# whole history. .pkgmeta points the packager's manual-changelog at it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/RELEASE_NOTES.md"

awk '/^## / { if (seen) exit; seen = 1 } seen' "$ROOT/CHANGELOG.md" | tr -d '\r' > "$OUT"
[[ -s "$OUT" ]] || { echo "No ## version section in CHANGELOG.md" >&2; exit 1; }
echo "$OUT"
