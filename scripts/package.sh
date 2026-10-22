#!/usr/bin/env bash
# Builds dist/FriendlyForever-<version>.zip in the layout WoW and CurseForge
# expect: one top-level FriendlyForever/ folder holding the .toc and exactly
# the files the .toc loads (plus README/CHANGELOG/LICENSE). Tests, tooling
# and editor settings never ship.
set -euo pipefail

ADDON="FriendlyForever"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOC="$ROOT/$ADDON.toc"

VERSION="$(sed -n 's/^## Version:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$TOC")"
[[ -n "$VERSION" ]] || { echo "No ## Version in $TOC" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/$ADDON"

cp "$TOC" "$STAGE/$ADDON/"
while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "${line// /}" || "$line" == \#* ]] && continue
    file="${line//\\//}"
    [[ -f "$ROOT/$file" ]] || { echo "TOC lists missing file: $file" >&2; exit 1; }
    mkdir -p "$STAGE/$ADDON/$(dirname "$file")"
    cp "$ROOT/$file" "$STAGE/$ADDON/$file"
done < "$TOC"
for extra in README.md CHANGELOG.md LICENSE; do
    [[ -f "$ROOT/$extra" ]] && cp "$ROOT/$extra" "$STAGE/$ADDON/"
done

mkdir -p "$ROOT/dist"
OUT="$ROOT/dist/$ADDON-$VERSION.zip"
rm -f "$OUT"
(cd "$STAGE" && zip -qrX "$OUT" "$ADDON")
echo "$OUT"
