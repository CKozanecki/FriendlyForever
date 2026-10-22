#!/usr/bin/env bash
# Fails if two addon zips hold different files. CI uses it to check that the
# BigWigs packager (releases) and scripts/package.sh (local builds) agree.
set -euo pipefail

[[ $# -eq 2 ]] || { echo "usage: $0 local.zip release.zip" >&2; exit 2; }

list() { unzip -Z1 "$1" | grep -v '/$' | sort; }

if diff <(list "$1") <(list "$2"); then
    echo "Packages match: $(list "$1" | wc -l | tr -d ' ') files"
else
    echo "::error::$2 and $1 hold different files (< only in local, > only in release)" >&2
    exit 1
fi
