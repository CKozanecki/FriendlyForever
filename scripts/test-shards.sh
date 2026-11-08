#!/usr/bin/env bash
# Splits the spec files into shards, so CI can run them in parallel jobs (#218).
#
#   scripts/test-shards.sh files <shards> <n>   the spec files of shard n (1..shards)
#   scripts/test-shards.sh check <shards>       fails unless every spec file is in exactly one shard
#   scripts/test-shards.sh count                how many spec files there are
#
# The split is by file: the slow files are listed below with their measured
# seconds (one machine, #218) and everything else counts 1. Heaviest first,
# each file goes to the lightest shard (the lowest number on a tie), so the
# split is the same on every machine. A new spec file needs no entry here: it
# lands in a shard by itself, and `check` (also run by CI's final job and by
# spec/repo_spec.lua) fails if one is ever in none or in two.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Same files busted runs: spec/, any depth, names containing _spec (.busted).
all_specs() { find spec -type f -name '*_spec*.lua' | LC_ALL=C sort; }

weight() {
    case "$1" in
        spec/guildhellos_spec.lua) echo 38 ;;
        spec/repo_spec.lua) echo 27 ;;
        spec/walkthrough_spec.lua) echo 12 ;;
        spec/phase1_chaos_spec.lua) echo 10 ;;
        spec/buffmodeauto_spec.lua | spec/rounds_spec.lua) echo 6 ;;
        spec/receipts_spec.lua | spec/ratelimit_spec.lua | spec/dev_setup_spec.lua | spec/exchange_spec.lua) echo 5 ;;
        *) echo 1 ;;
    esac
}

# Prints "<shard> <file>" for every spec file.
assign() {
    local shards="$1" file
    while IFS= read -r file; do
        printf '%s %s\n' "$(weight "$file")" "$file"
    done < <(all_specs) | LC_ALL=C sort -k1,1nr -k2,2 | awk -v n="$shards" '
        BEGIN { for (i = 1; i <= n; i++) load[i] = 0 }
        {
            best = 1
            for (i = 2; i <= n; i++) if (load[i] < load[best]) best = i
            load[best] += $1
            print best, $2
        }'
}

positive() { [[ "$1" =~ ^[1-9][0-9]*$ ]] || { echo "test-shards: '$1' is not a positive number" >&2; exit 2; }; }

case "${1:-}" in
    files)
        positive "${2:-}"; positive "${3:-}"
        [ "$3" -le "$2" ] || { echo "test-shards: shard $3 of $2 doesn't exist" >&2; exit 2; }
        # TEST_SHARDS_FAULT is for spec/repo_spec.lua only: it breaks the split
        # on purpose, to prove `check` notices.
        assign "$2" | awk -v i="$3" -v fault="${TEST_SHARDS_FAULT:-}" '
            fault == "drop" && NR == 1 { next }
            fault == "dup" && NR == 1 { print $2 }
            $1 == i { print $2 }' | LC_ALL=C sort
        ;;
    count)
        all_specs | wc -l | tr -d ' '
        ;;
    check)
        positive "${2:-}"
        shards="$2"
        status=0
        total=$(all_specs | wc -l | tr -d ' ')
        [ "$total" -gt 0 ] || { echo "test-shards: no spec files found" >&2; exit 1; }
        listed="$(for i in $(seq 1 "$shards"); do "$0" files "$shards" "$i"; done | LC_ALL=C sort)"
        missing="$(comm -23 <(all_specs) <(printf '%s\n' "$listed" | uniq))"
        twice="$(printf '%s\n' "$listed" | uniq -d)"
        extra="$(comm -13 <(all_specs) <(printf '%s\n' "$listed" | uniq))"
        [ -z "$missing" ] || { echo "in no shard:"; echo "$missing"; status=1; }
        [ -z "$twice" ] || { echo "in more than one shard:"; echo "$twice"; status=1; }
        [ -z "$extra" ] || { echo "not a spec file:"; echo "$extra"; status=1; }
        [ "$status" -ne 0 ] || echo "all $total spec files are in exactly one of $shards shards"
        exit "$status"
        ;;
    *)
        echo "usage: test-shards.sh files <shards> <n> | check <shards> | count" >&2
        exit 2
        ;;
esac
