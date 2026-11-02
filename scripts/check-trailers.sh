#!/usr/bin/env bash
# Checks that each agent's commits stay on its own branches (#187).
#
#   scripts/check-trailers.sh <base> <head> <branch>
#
# On a claude/* branch every commit in base..head must carry a
# "Claude-Session:" trailer and no "Agent: codex" trailer. On codex/* every
# commit must carry "Agent: codex <model>" and no "Claude-Session:" line.
# Other branches aren't checked. A merge commit is exempt when one of its
# parents is already in base, so merging main in needs no trailer; any other
# merge is checked like a commit.
#
# Commit messages and the branch name are untrusted (anyone can push a
# commit or name a branch): they're only ever read as data, compared with
# [[ ]] and printed with printf '%s'. Never eval them or build a command from
# them.
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "usage: $0 <base> <head> <branch>" >&2
    exit 2
fi
base=$1 head=$2 branch=$3

case "$branch" in
    claude/*) product=claude ;;
    codex/*) product=codex ;;
    *)
        printf 'Branch %s has no agent prefix: nothing to check.\n' "$branch"
        exit 0
        ;;
esac

base=$(git rev-parse --verify --quiet "${base}^{commit}") || { echo "base isn't a commit" >&2; exit 2; }
head=$(git rev-parse --verify --quiet "${head}^{commit}") || { echo "head isn't a commit" >&2; exit 2; }

# One trailer key's values, one per line. Git's own parser reads the trailer
# block (keys are case-insensitive), so a line in the body doesn't count.
trailer() { git log -1 --format="%(trailers:key=$2,valueonly,unfold)" "$1"; }

failed=0
fail() {
    printf '::error::%s %s\n' "$1" "$2"
    failed=1
}

checked=0
while read -r commit; do
    [[ -n $commit ]] || continue
    read -r -a parents <<< "$(git log -1 --format=%P "$commit")"
    if (( ${#parents[@]} > 1 )); then
        exempt=0
        for parent in "${parents[@]}"; do
            if git merge-base --is-ancestor "$parent" "$base"; then exempt=1; fi
        done
        (( exempt )) && continue
    fi
    checked=$((checked + 1))
    short=$(git rev-parse --short "$commit")
    session=$(trailer "$commit" Claude-Session)
    agent=$(trailer "$commit" Agent)
    # Any "Claude-Session:" line, trailer or not, marks a Claude commit.
    message=$(git log -1 --format=%B "$commit")
    claudeLine=0
    while IFS= read -r line; do
        shopt -s nocasematch
        [[ $line == claude-session:* ]] && claudeLine=1
        shopt -u nocasematch
    done <<< "$message"
    codex=0
    while IFS= read -r value; do
        [[ $value =~ ^codex\ [^[:space:]]+ ]] && codex=1
    done <<< "$agent"

    if [[ $product == claude ]]; then
        [[ $session =~ [^[:space:]] ]] || fail "$short" "on a claude/ branch has no Claude-Session: trailer."
        (( codex == 0 )) || fail "$short" "on a claude/ branch carries an Agent: codex trailer."
    else
        (( codex == 1 )) || fail "$short" "on a codex/ branch has no 'Agent: codex <model>' trailer."
        (( claudeLine == 0 )) || fail "$short" "on a codex/ branch carries a Claude-Session: line."
    fi
done < <(git rev-list "$base..$head")

if (( failed )); then
    printf 'Commits on %s branches must carry the trailers in AGENTS.md (Pull requests).\n' "$product"
    exit 1
fi
printf 'Checked %d commit(s) on a %s/ branch: every trailer is right.\n' "$checked" "$product"
