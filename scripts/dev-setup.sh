#!/usr/bin/env bash
# Installs the pinned Lua toolchain (Lua 5.1, LuaRocks, busted, luacheck)
# into TOOLS, checking every download against scripts/dev-setup.lock (#103).
# `make setup`, CI and the claude.ai environment all run it.
#
#   scripts/dev-setup.sh [TOOLS]     default: ~/.cache/friendlyforever
#
# Re-running it is quick: an install whose pins match is left alone, with no
# downloads. A changed pin or a damaged install is rebuilt from scratch. A
# failed or mismatched download stops it before anything is installed, and
# only a finished, checked install is marked as good.
set -euo pipefail

# The pins. CONTRIBUTING.md lists the same versions; spec/repo_spec.lua
# checks they agree.
HEREROCKS_VERSION="0.25.1"
LUA_VERSION="5.1.5"
LUAROCKS_VERSION="3.8.0"
BUSTED_VERSION="2.2.0-1"
LUACHECK_VERSION="1.2.0-1"

# Every rock, each after its dependencies, so nothing is resolved (or
# downloaded) at install time. busted and luacheck's dependencies are pinned
# to the versions LuaRocks chose for them when this was written.
ROCKS=(
    luafilesystem-1.9.0-1 argparse-0.7.2-1 "luacheck-$LUACHECK_VERSION"
    lua_cliargs-3.0-2 luasystem-0.7.1-1 dkjson-2.11-1 say-1.4.1-3
    luassert-1.9.0-1 lua-term-0.8-1 penlight-1.15.0-1 mediator_lua-1.1.2-0
    "busted-$BUSTED_VERSION"
)

# Rocks published only as a rockspec are built from their source archive.
rock_source() {
    case "$1" in
        lua-term-0.8-1) echo "lua-term-0.08.tar.gz" ;;
        mediator_lua-1.1.2-0) echo "mediator_lua-1.1.2-0.tar.gz" ;;
        *) echo "" ;;
    esac
}

HELP="CONTRIBUTING.md#local-setup"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
# DEV_SETUP_LOCK and DEV_SETUP_TEST are for spec/dev_setup_spec.lua only.
LOCK="${DEV_SETUP_LOCK:-$(dirname "$SELF")/dev-setup.lock}"
PROTOCOLS="=https"
[[ "${DEV_SETUP_TEST:-}" == 1 ]] && PROTOCOLS="=https,file"

say() { printf 'dev-setup: %s\n' "$*"; }
die() { printf 'dev-setup: %s\n' "$@" >&2; exit 1; }

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$@" | cut -d' ' -f1
    else
        shasum -a 256 "$@" | cut -d' ' -f1
    fi
}

for tool in python3 curl tar make; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is needed and wasn't found."
done
command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1 \
    || die "a C compiler (cc or gcc) is needed and wasn't found."
command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 \
    || die "sha256sum or shasum is needed and wasn't found."

TOOLS="${1:-${TOOLS:-$HOME/.cache/friendlyforever}}"
case "$TOOLS" in
    *[[:space:]]*) die "LuaRocks can't build in a path with spaces: $TOOLS" \
        "Choose another folder: make setup TOOLS=/some/path" ;;
esac
mkdir -p "$TOOLS"
TOOLS="$(cd "$TOOLS" && pwd)"
LUA_DIR="$TOOLS/lua51"
DOWNLOADS="$TOOLS/downloads"
STAMP="$LUA_DIR/.dev-setup-stamp"
LUAROCKS="$LUA_DIR/bin/luarocks"

# The lock file is checked whole before anything is fetched: a name is a
# plain file name, a checksum is 64 hex digits, and every URL is https.
[[ -f "$LOCK" ]] || die "checksum file not found: $LOCK"
names=" "
while read -r name sum urls; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "bad file name in $LOCK: $name"
    [[ "$sum" =~ ^[0-9a-f]{64}$ ]] || die "bad checksum for $name in $LOCK"
    [[ -n "$urls" ]] || die "no URL for $name in $LOCK"
    for url in $urls; do
        [[ "$url" == https://* || ( "$PROTOCOLS" == *file && "$url" == file://* ) ]] \
            || die "not an https URL for $name in $LOCK: $url"
    done
    [[ "$names" != *" $name "* ]] || die "$name is listed twice in $LOCK"
    names="$names$name "
done < "$LOCK"

entry() { awk -v n="$1" '$1 == n { $1 = ""; print; exit }' "$LOCK"; }

# The stamp names exactly what was installed: this script and its checksums.
WANT="$(cat "$SELF" "$LOCK" | sha256)"

installed() {
    [[ -f "$STAMP" && "$(cat "$STAMP")" == "$WANT" ]] || return 1
    [[ "$("$LUA_DIR/bin/busted" --version 2>/dev/null)" == "${BUSTED_VERSION%-*}" ]] || return 1
    "$LUA_DIR/bin/luacheck" --version 2>/dev/null | grep -qx "Luacheck: ${LUACHECK_VERSION%-*}"
}

if installed; then
    say "the pinned toolchain is already installed in $LUA_DIR"
    exit 0
fi

# Downloads into DOWNLOADS, keeping a file only once its checksum matches.
# A cached file is checked again before it's used.
fetch() {
    local name="$1" sum urls url host final err got dest="$DOWNLOADS/$1" part="$DOWNLOADS/$1.part" failed=""
    local line
    line="$(entry "$name")"
    [[ -n "$line" ]] || die "$name has no checksum in $LOCK"
    read -r sum urls <<<"$line"
    if [[ -f "$dest" ]]; then
        [[ "$(sha256 "$dest")" == "$sum" ]] && return 0
        say "cached $name doesn't match its checksum; downloading it again"
    fi
    mkdir -p "$DOWNLOADS"
    for url in $urls; do
        host="${url#*://}"
        host="${host%%/*}"
        say "downloading $name from $host"
        rm -f "$part"
        if final="$(curl -fsS -L --proto "$PROTOCOLS" --proto-redir =https --tlsv1.2 \
            --connect-timeout 20 --max-time 600 --retry 2 -w '%{url_effective}' \
            -o "$part" "$url" 2>"$part.err")"; then
            # Name a redirect's host too: the network policy has to allow it.
            final="${final#*://}"
            [[ "${final%%/*}" == "$host" ]] || say "  (redirected to ${final%%/*})"
            rm -f "$part.err"
            got="$(sha256 "$part")"
            if [[ "$got" != "$sum" ]]; then
                rm -f "$part"
                die "checksum mismatch for $name from $url" \
                    "  expected $sum" \
                    "  got      $got" \
                    "Nothing was installed. Don't work around this: the file isn't the one that was reviewed."
            fi
            mv "$part" "$dest"
            return 0
        fi
        err="$(head -n 1 "$part.err")"
        rm -f "$part" "$part.err"
        failed="$failed"$'\n'"  $host: ${err:-no response}"
    done
    die "couldn't download $name.$failed" \
        "If a host is blocked by the network policy, allow every host listed in $HELP."
}

files=("hererocks-$HEREROCKS_VERSION-py3-none-any.whl" "lua-$LUA_VERSION.tar.gz" "luarocks-$LUAROCKS_VERSION.tar.gz")
for rock in "${ROCKS[@]}"; do
    source="$(rock_source "$rock")"
    if [[ -n "$source" ]]; then
        files+=("$rock.rockspec" "$source")
    else
        files+=("$rock.src.rock")
    fi
done
for name in "${files[@]}"; do
    fetch "$name"
done

# Everything is verified: build from scratch. Until the stamp is written the
# install isn't trusted, and a failed build removes it.
started=$SECONDS
rm -rf "$LUA_DIR" "$TOOLS/venv" # venv: the hererocks install of the old make setup
WORK="$(mktemp -d "$TOOLS/build.XXXXXX")"
finished=""
cleanup() {
    rm -rf "$WORK"
    if [[ -z "$finished" ]]; then
        rm -rf "$LUA_DIR"
        printf 'dev-setup: %s\n' "the install failed and was removed; run it again once the error above is fixed." >&2
    fi
}
trap cleanup EXIT
unset LUA_PATH LUA_CPATH LUA_INIT LUAROCKS_CONFIG

python3 -I -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extract("hererocks.py", sys.argv[2])' \
    "$DOWNLOADS/hererocks-$HEREROCKS_VERSION-py3-none-any.whl" "$WORK"
# hererocks finds the verified archives in DOWNLOADS (and checks them against
# its own checksums too), so it downloads nothing.
python3 -I "$WORK/hererocks.py" "$LUA_DIR" -l "$LUA_VERSION" -r "$LUAROCKS_VERSION" \
    --downloads "$DOWNLOADS" --no-git-cache

for rock in "${ROCKS[@]}"; do
    source="$(rock_source "$rock")"
    if [[ -n "$source" ]]; then
        mkdir "$WORK/$rock"
        tar -xzf "$DOWNLOADS/$source" -C "$WORK/$rock"
        dirs=("$WORK/$rock"/*/)
        [[ ${#dirs[@]} -eq 1 && -d "${dirs[0]}" ]] || die "$source didn't unpack into one folder"
        (cd "${dirs[0]}" && "$LUAROCKS" make --deps-mode=none "$DOWNLOADS/$rock.rockspec")
    else
        "$LUAROCKS" build --deps-mode=none "$DOWNLOADS/$rock.src.rock"
    fi
done

# Exactly the pinned rocks, and tools that run and report the pinned versions.
want="$(printf '%s\n' "${ROCKS[@]}" | sort)"
have="$("$LUAROCKS" list --porcelain | awk '{ print $1 "-" $2 }' | sort)"
[[ "$have" == "$want" ]] || die "the installed rocks aren't the pinned ones:" "$have"
printf '%s\n' "$WANT" > "$STAMP"
installed || { rm -f "$STAMP"; die "busted or luacheck doesn't run or isn't the pinned version."; }
finished=1
say "installed Lua $LUA_VERSION, LuaRocks $LUAROCKS_VERSION, busted $BUSTED_VERSION and luacheck $LUACHECK_VERSION in $LUA_DIR ($((SECONDS - started))s)"
