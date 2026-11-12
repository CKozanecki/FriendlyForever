#!/usr/bin/env bash
# Writes RELEASE_NOTES.md with only the newest version's section of
# CHANGELOG.md, so each CurseForge file shows its own notes rather than the
# whole history. .pkgmeta points the packager's manual-changelog at it.
#
# Each entry's issue tag, "(#27)" or "(#27, #52)" at the end, is left out:
# it traces the entry to its spec for us and means nothing to players.
#
# Notes waiting for the next release (changes/*.md fragments, or bullets
# under "### Unreleased") aren't in that section until the release PR gathers
# them (#261, `make changelog`). With --release, as the Release workflow and a
# release PR's CI run it, any still waiting fails: they would be left out of
# the release notes.
#
# Usage: release-notes.sh [--release] [changelog] [output] [changes dir]
# (defaults: the repo's files).
set -euo pipefail

RELEASE=0
if [[ "${1:-}" == "--release" ]]; then RELEASE=1; shift; fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHANGELOG="${1:-$ROOT/CHANGELOG.md}"
OUT="${2:-$ROOT/RELEASE_NOTES.md}"
CHANGES="${3:-$ROOT/changes}"

if (( RELEASE )); then
    waiting="$(ls -A "$CHANGES" 2>/dev/null || true)"
    if [[ -n "$waiting" ]]; then
        echo "Release notes would leave out changes/ (run make changelog VERSION=x.y.z in the release PR):" >&2
        sed 's/^/  /' <<< "$waiting" >&2
        exit 1
    fi
    if tr -d '\r' < "$CHANGELOG" | grep -Eq '^ {0,3}### Unreleased[[:space:]]*$'; then
        echo "Release notes would leave out $CHANGELOG's ### Unreleased section (run make changelog VERSION=x.y.z in the release PR)" >&2
        exit 1
    fi
fi

# Write beside the output and move it into place, so a second run or a reader
# never finds the file empty (#178).
TMP="$(mktemp "$OUT.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

awk '/^## / { if (seen) exit; seen = 1 } seen' "$CHANGELOG" | tr -d '\r' \
    | LC_ALL=C sed -E 's/ \(#[1-9][0-9]*(, #[1-9][0-9]*)*\)[[:space:]]*$//' > "$TMP"
[[ -s "$TMP" ]] || { echo "No ## version section in $CHANGELOG" >&2; exit 1; }
chmod 644 "$TMP"
mv -f "$TMP" "$OUT"
echo "$OUT"
