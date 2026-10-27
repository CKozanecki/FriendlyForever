#!/usr/bin/env bash
# Writes RELEASE_NOTES.md with only the newest version's section of
# CHANGELOG.md, so each CurseForge file shows its own notes rather than the
# whole history. .pkgmeta points the packager's manual-changelog at it.
#
# Each entry's issue tag, "(#27)" or "(#27, #52)" at the end, is left out:
# it traces the entry to its spec for us and means nothing to players.
#
# Usage: release-notes.sh [changelog] [output] (defaults: the repo's files).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHANGELOG="${1:-$ROOT/CHANGELOG.md}"
OUT="${2:-$ROOT/RELEASE_NOTES.md}"

awk '/^## / { if (seen) exit; seen = 1 } seen' "$CHANGELOG" | tr -d '\r' \
    | LC_ALL=C sed -E 's/ \(#[1-9][0-9]*(, #[1-9][0-9]*)*\)[[:space:]]*$//' > "$OUT"
[[ -s "$OUT" ]] || { echo "No ## version section in $CHANGELOG" >&2; exit 1; }
echo "$OUT"
