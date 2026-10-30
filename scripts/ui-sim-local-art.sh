#!/usr/bin/env bash
# Takes the UI simulator's screenshots with WoW Forever's own art and fonts,
# read from the owner's local Forever install (#139). Never run in CI: CI has
# no install, and the PNGs this writes hold Blizzard's art, so they stay on
# this computer. Never commit, push, attach or upload them, and label any
# shot used publicly as simulated. See "Screenshots with Forever's art" in
# docs/ui-simulator.md.
#
#   scripts/ui-sim-local-art.sh [--size WxH] [--product CODE] OUTPUT_FOLDER [FOREVER_INSTALL]
#
# FOREVER_INSTALL is the folder holding the install's Data/ and .build.info
# (or set WOW_INSTALL_PATH). It's never guessed. OUTPUT_FOLDER must be
# outside any git repository.
#
# The same sandbox and pins as the screenshot job in .github/workflows/
# ui-sim.yml, with the simulator built for Forever (client-wowforever):
# - the simulator is built from its pinned commit, on build and render images
#   from bases pinned by digest. Never upstream's release binaries;
# - only cargo fetch has network, and it runs none of the crates' code. The
#   build and every shot run with no network, no capabilities and no
#   privilege escalation;
# - a shot sees, read-only, only the install's Data/ and .build.info, and a
#   minimal .product.db this script writes from .build.info (the launcher's
#   own isn't read: the simulator can't decode the live one, #139). Never
#   WTF/ (it holds the account name), Interface/AddOns or the whole install. Its root file system is read-only; only a tmpfs and
#   the output's shots/ folder are writable. The host writes its logs and
#   README beside shots/, where no container can plant a link;
# - Forever's UI code comes from Gethe's wow-ui-source at the commit the
#   simulator pins, so the simulator never syncs it from the install or
#   Blizzard's CDN. Nothing downloads game files;
# - no secrets: none are passed, and none are needed.
#
# Runs on an Intel Mac with Docker Desktop, so it keeps to macOS's bash 3.2
# and its BSD tools.
set -euo pipefail

# Pins: the same simulator release and base images as ui-sim.yml.
readonly SIM_REPO=https://github.com/Osso/wow-ui-sim.git
readonly SIM_COMMIT=3b369ee1aafeb85089b7c63e8a0a99e56f8c2dd0 # v0.1.36
readonly BUILD_BASE=rust@sha256:e90e846de4124376164ddfbaab4b0774c7bdeef5e738866295e5a90a34a307a2 # 1.92-bookworm
readonly RENDER_BASE=debian@sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3 # bookworm-slim
# Forever's UI code, 1.60.1.70532: the Gethe commit the simulator's
# data/blizzard-ui-builds/wowforever.json pins (checked below), whose tree is
# exactly its data/blizzard-ui-files/wowforever.txt.
readonly FOREVER_UI_REPO=https://github.com/Gethe/wow-ui-source.git
readonly FOREVER_UI_COMMIT=ca8368f2f2380cbe696854f7f2646387c278a61b
readonly FOREVER_UI_VERSION=1.60.1.70532
# The simulator's Forever profile reads this CASC product
# (src/asset_resolver_config.rs). A launch check on #50; --product overrides.
readonly DEFAULT_PRODUCT=wowf
# The shots' size: what most players play at, the owner's choice (#139).
# CI's shots stay at 1024x768; --size takes any other.
readonly DEFAULT_SIZE=1920x1080

readonly BUILD_IMAGE=ff-art-build
readonly RENDER_IMAGE=ff-art-render
readonly CARGO_VOLUME=ff-art-cargo
readonly TARGET_VOLUME=ff-art-target
readonly LABEL=friendlyforever.ui-sim-local-art
# Run in a shot's container before the simulator: links Forever's UI code,
# mounted read-only at /forever-ui, into the simulator's cache on the tmpfs.
# (Mounted there directly, its parent folders would belong to root, and the
# simulator couldn't write the art it extracts beside it.)
readonly LINK_UI='cache="$XDG_CACHE_HOME/wow-ui-sim/blizzard-ui/wowforever" && mkdir -p "$cache" && ln -s /forever-ui "$cache/AddOns" && exec /target/release/wow-sim "$@"'

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# Seconds a shot may run before it's killed. CI allows 180; each shot here
# also reads the install's indexes first.
SHOT_SECONDS="${UI_SIM_SHOT_SECONDS:-300}"

die() {
    printf '\nui-sim-local-art: %s\n' "$1" >&2
    shift
    while [ $# -gt 0 ]; do printf '  %s\n' "$1" >&2; shift; done
    exit 1
}

say() { printf '==> %s\n' "$1"; }

usage() {
    cat <<'USAGE'
Usage: scripts/ui-sim-local-art.sh [--size WxH] [--product CODE] OUTPUT_FOLDER [FOREVER_INSTALL]

Takes the UI simulator's screenshots with Forever's own art, from your
local install. OUTPUT_FOLDER must be outside any git repository.
FOREVER_INSTALL is the folder holding Data/ and .build.info, usually
"/Applications/World of Warcraft"; or set WOW_INSTALL_PATH instead.
--size WxH sets the shots' size in pixels (default: 1920x1080; CI's is
1024x768). --product CODE picks the install's CASC product (default: wowf).
USAGE
}

# The path with symlinks resolved, for a folder that exists.
real_dir() { (cd "$1" 2>/dev/null && pwd -P); }

# Whether path $1 is folder $2 or inside it. Both resolved.
inside() {
    case "$1/" in
        "$2"/*) return 0 ;;
    esac
    return 1
}

# Paths reach docker -v as "host:container:ro", so a colon or a line break
# in one would change the mount.
check_mountable() {
    case "$2" in
        *:* | *$'\n'* | *$'\r'*)
            die "$1 can't contain a colon or a line break: $2" ;;
    esac
}

# The install: the folder that holds Data/data (the simulator's own test of
# a WoW install) and the metadata it reads, .build.info and .product.db.
resolve_install() {
    local given="$1"
    [ -n "$given" ] || die "No Forever install given." \
        "Pass the folder that holds the install's Data/ and .build.info, for example:" \
        "  scripts/ui-sim-local-art.sh ~/ui-sim-art \"/Applications/World of Warcraft\"" \
        "or set WOW_INSTALL_PATH. The script never guesses it."
    [ -d "$given" ] || die "The Forever install folder doesn't exist: $given"
    INSTALL="$(real_dir "$given")" || die "Can't open the Forever install folder: $given"
    check_mountable "The Forever install's path" "$INSTALL"
    local missing=""
    [ -d "$INSTALL/Data/data" ] || missing="$missing Data/data/"
    [ -d "$INSTALL/Data/config" ] || missing="$missing Data/config/"
    [ -d "$INSTALL/Data/indices" ] || missing="$missing Data/indices/"
    [ -f "$INSTALL/.build.info" ] || missing="$missing .build.info"
    [ -z "$missing" ] || die "$INSTALL isn't a WoW install: it has no$missing." \
        "Pass the folder that holds Data/ and .build.info (the top of the install," \
        "not its _retail_ or Forever subfolder)."
}

# The CASC products .build.info lists, one per line, as plain codes only:
# the file is the game's, so nothing else from it is printed.
installed_products() {
    awk -F'|' '
        NR == 1 { for (i = 1; i <= NF; i++) if ($i ~ /^Product!/) col = i; next }
        col && $col ~ /^[A-Za-z0-9_]+$/ { print $col }
    ' "$INSTALL/.build.info" | sort -u
}

check_product() {
    case "$PRODUCT" in
        "" | *[!a-z0-9_]*) die "--product must be a CASC product code, such as wowf: '$PRODUCT'" ;;
    esac
    [ "${#PRODUCT}" -le 32 ] || die "--product is too long: $PRODUCT"
    local found
    found="$(installed_products | tr '\n' ' ')"
    case " $found " in
        *" $PRODUCT "*) return 0 ;;
    esac
    die "This install has no '$PRODUCT' product in its .build.info." \
        "Products it lists: ${found:-none}" \
        "If Forever is one of those under another code, run again with --product CODE."
}

# The product's active build from .build.info, as "build-key|install-key|
# version", checked: exactly one active row, keys of 32 hex digits (the
# install key may be absent), a plain version. Nothing else from the game's
# file is used.
active_build() {
    local rows count line build install version
    rows="$(awk -F'|' -v product="$PRODUCT" '
        NR == 1 {
            for (i = 1; i <= NF; i++) {
                name = $i; sub(/!.*/, "", name)
                col[name] = i
            }
            next
        }
        $col["Product"] == product && $col["Active"] == "1" {
            print $col["Build Key"] "|" $col["Install Key"] "|" $col["Version"]
        }
    ' "$INSTALL/.build.info")"
    count="$(printf '%s' "$rows" | grep -c . || true)"
    [ "$count" -eq 1 ] || die "The install's .build.info has $count active '$PRODUCT' builds, not 1." \
        "Open the game once from the Battle.net launcher so it settles on one, then try again."
    line="$(printf '%s' "$rows" | tr -d '\r')"
    build="${line%%|*}"
    line="${line#*|}"
    install="${line%%|*}"
    version="${line#*|}"
    [ "${#build}" -eq 32 ] && [ -n "${build##*[!0-9a-f]*}" ] \
        || die "The install's active '$PRODUCT' build key isn't one this script can read."
    if [ -n "$install" ]; then
        [ "${#install}" -eq 32 ] && [ -n "${install##*[!0-9a-f]*}" ] \
            || die "The install's active '$PRODUCT' install key isn't one this script can read."
    fi
    [ "${#version}" -le 64 ] && [ -n "${version##*[!0-9A-Za-z._-]*}" ] \
        || die "The install's active '$PRODUCT' version isn't one this script can read."
    [ -f "$INSTALL/Data/config/${build:0:2}/${build:2:2}/$build" ] \
        || die "The install has no build config for its active '$PRODUCT' build ($build)." \
            "Let the Battle.net launcher finish updating the game, then try again."
    echo "$build|$install|$version"
}

# One byte, by its number.
byte() { printf "\\$(printf '%03o' "$1")"; }

# A protobuf varint, for the lengths below.
varint() {
    local n="$1"
    while [ "$n" -ge 128 ]; do byte $(((n % 128) + 128)); n=$((n / 128)); done
    byte "$n"
}

# How many bytes varint takes for $1.
varint_size() { if [ "$1" -ge 128 ]; then echo 2; else echo 1; fi; }

# The simulator finds the active build only through .product.db, and its
# decoder (cascette-rs's product_db.rs, after TACTLib's ProtoDatabase.cs)
# can't read the live launcher's (#139). So the shots get this one instead:
# just the fields that decoder reads, for the product's active build in
# .build.info. Database { product_install (1) { product_code (2),
# cached_product_state (4) { base_product_state (1) { current_version_str (7),
# active_build_key (14), active_install_key (16) } } } }.
write_product_db() {
    local info build install version base state entry file="$WORK/product-db/.product.db"
    # Its own line, so a refusal from active_build stops the script.
    info="$(active_build)"
    build="${info%%|*}"
    info="${info#*|}"
    install="${info%%|*}"
    version="${info#*|}"
    base=$((2 + ${#version} + 2 + ${#build}))
    [ -z "$install" ] || base=$((base + 3 + ${#install}))
    state=$((1 + $(varint_size "$base") + base))
    entry=$((2 + ${#PRODUCT} + 1 + $(varint_size "$state") + state))
    chmod -R u+w "$WORK/product-db" 2>/dev/null || true
    rm -rf "$WORK/product-db"
    mkdir -p "$WORK/product-db"
    {
        byte 10; varint "$entry"
        byte 18; varint "${#PRODUCT}"; printf '%s' "$PRODUCT"
        byte 34; varint "$state"
        byte 10; varint "$base"
        byte 58; varint "${#version}"; printf '%s' "$version"
        byte 114; varint "${#build}"; printf '%s' "$build"
        if [ -n "$install" ]; then byte 130; byte 1; varint "${#install}"; printf '%s' "$install"; fi
    } > "$file"
    chmod -R a-w "$WORK/product-db"
    echo "Build:    $PRODUCT $version, build config $build"
}

# The output folder: new, or holding only what an earlier run made (shots/,
# logs/ and the README). Never inside a git repository (this one or any
# other), the install or the script's working folder.
resolve_output() {
    local given="$1" parent base entry
    [ -n "$given" ] || { usage >&2; die "No output folder given."; }
    given="${given%/}"
    [ -n "$given" ] || die "The output folder can't be /."
    if [ -e "$given" ] && [ ! -d "$given" ]; then die "The output path isn't a folder: $given"; fi
    if [ -d "$given" ]; then
        OUT="$(real_dir "$given")" || die "Can't open the output folder: $given"
    else
        parent="$(dirname "$given")"
        base="$(basename "$given")"
        [ -d "$parent" ] || die "The output folder's parent doesn't exist: $parent"
        OUT="$(real_dir "$parent")/$base" || die "Can't open the output folder's parent: $parent"
    fi
    check_mountable "The output folder's path" "$OUT"
    if inside "$OUT" "$REPO_ROOT"; then
        die "The output folder is inside this repository: $OUT" \
            "Its PNGs hold Blizzard's art, so they must never be committed. Choose a folder outside it."
    fi
    local probe="$OUT"
    [ -d "$probe" ] || probe="$(dirname "$OUT")"
    if [ "$(git -C "$probe" rev-parse --is-inside-work-tree 2>/dev/null || true)" = "true" ]; then
        die "The output folder is inside a git repository: $OUT" \
            "Its PNGs hold Blizzard's art, so they must never be committed. Choose a folder outside any repository."
    fi
    if inside "$OUT" "$INSTALL"; then die "The output folder is inside the Forever install: $OUT"; fi
    if inside "$OUT" "$WORK"; then die "The output folder is inside the script's working folder: $OUT"; fi
    [ -d "$OUT" ] || return 0
    for entry in "$OUT"/* "$OUT"/.[!.]* "$OUT"/..?*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        if [ ! -L "$entry" ]; then
            case "${entry##*/}" in
                shots | logs) [ -d "$entry" ] && continue ;;
                README-simulated.txt) [ -f "$entry" ] && continue ;;
            esac
        fi
        die "The output folder holds other files, such as ${entry##*/}: $OUT" \
            "Give a new folder, or one an earlier run of this script made."
    done
}

# The shots' size, as WIDTHxHEIGHT in pixels: from 640x480 to 3840x2160.
check_size() {
    case "$SIZE" in
        [1-9]*x[1-9]*) ;;
        *) die "--size must be WIDTHxHEIGHT in pixels, such as 1920x1080: '$SIZE'" ;;
    esac
    WIDTH="${SIZE%%x*}"
    HEIGHT="${SIZE#*x}"
    case "$WIDTH$HEIGHT" in
        *[!0-9]*) die "--size must be WIDTHxHEIGHT in pixels, such as 1920x1080: '$SIZE'" ;;
    esac
    [ "${#WIDTH}" -le 4 ] && [ "${#HEIGHT}" -le 4 ] && [ "$WIDTH" -ge 640 ] && [ "$WIDTH" -le 3840 ] \
        && [ "$HEIGHT" -ge 480 ] && [ "$HEIGHT" -le 2160 ] \
        || die "--size must be from 640x480 to 3840x2160: '$SIZE'"
}

check_seconds() {
    case "$SHOT_SECONDS" in
        "" | *[!0-9]* | 0*) die "UI_SIM_SHOT_SECONDS must be a whole number of seconds: '$SHOT_SECONDS'" ;;
    esac
    [ "$SHOT_SECONDS" -le 3600 ] || die "UI_SIM_SHOT_SECONDS is over an hour: $SHOT_SECONDS"
}

check_tools() {
    local tool
    for tool in git make zip unzip awk docker; do
        command -v "$tool" >/dev/null 2>&1 || die "This needs '$tool', which isn't installed." \
            "git, make, zip and unzip come with Apple's Command Line Tools (xcode-select --install)," \
            "and Docker with Docker Desktop."
    done
}

check_docker() {
    docker info >/dev/null 2>&1 || die "Docker isn't running." "Start Docker Desktop, wait for it to say it's running, then try again."
    local arch memory cpus
    arch="$(docker info --format '{{.Architecture}}' 2>/dev/null || true)"
    case "$arch" in
        x86_64 | amd64) ;;
        *) die "Docker runs on '$arch'. The pinned images are for Intel (x86_64) Macs and PCs only." ;;
    esac
    memory="$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
    case "$memory" in "" | *[!0-9]*) memory=0 ;; esac
    if [ "$memory" -lt 7500000000 ]; then
        printf 'Warning: Docker Desktop has under 8 GB of memory; the build may run out.\n'
        printf '  Raise it in Docker Desktop: Settings, Resources, Memory.\n'
    fi
    cpus="$(docker info --format '{{.NCPU}}' 2>/dev/null || echo 1)"
    case "$cpus" in "" | *[!0-9]* | 0) cpus=1 ;; esac
    SHOT_CPUS=3
    [ "$cpus" -ge 3 ] || SHOT_CPUS="$cpus"
}

# Kills and removes any shot container still there: after an interruption,
# or one left by an earlier run.
cleanup_containers() {
    local cid
    for cid in $(docker ps -aq --filter "label=$LABEL" 2>/dev/null); do
        docker kill "$cid" >/dev/null 2>&1 || true
        docker rm -f "$cid" >/dev/null 2>&1 || true
    done
}

# However the script ends, Ctrl-C included, no shot container is left.
install_traps() {
    trap 'cleanup_containers' EXIT
    trap 'exit 130' INT TERM
}

# The packaged addon as it ships, as CI loads it.
stage_addon() {
    say "Packaging the addon"
    local zip
    zip="$(make -s -C "$REPO_ROOT" package | tail -n 1)"
    [ -f "$zip" ] || die "make package didn't make the addon's zip."
    chmod -R u+w "$WORK/addons" 2>/dev/null || true
    rm -rf "$WORK/addons"
    mkdir -p "$WORK/addons"
    unzip -q "$zip" -d "$WORK/addons"
    chmod -R a-w "$WORK/addons"
}

# The options panel's tabs, one shot each: ui-sim.yml's OPTIONS_TABS, so the
# two can't drift apart. Plain tab names only.
options_tabs() {
    local tabs
    tabs="$(sed -n 's/^ *OPTIONS_TABS: *//p' "$REPO_ROOT/.github/workflows/ui-sim.yml" | head -n 1)"
    [ -n "$tabs" ] || die "ui-sim.yml has no OPTIONS_TABS list."
    # Checked as a whole before it's ever split, so it can't hold a pattern.
    case "$tabs" in
        *[!a-z0-9\ -]*) die "ui-sim.yml's OPTIONS_TABS has a name that isn't plain: $tabs" ;;
    esac
    echo "$tabs"
}

# One script per state of the buff-back button and per filled options page,
# as ui-sim.yml stages them: the scenarios' own setup, then what to show.
stage_shot_scripts() {
    local states="$WORK/shot-lua" state page
    chmod -R u+w "$states" 2>/dev/null || true
    rm -rf "$states"
    mkdir -p "$states"
    for state in favour buffmode; do
        { cat "$REPO_ROOT/uitests/button_states.lua"; printf '\nFriendlyForeverUIStates.Show("%s")\n' "$state"; } \
            > "$states/$state.lua"
    done
    for page in general ledger; do
        { cat "$REPO_ROOT/uitests/pages.lua"; printf '\nFriendlyForeverUIPages.Show("%s")\n' "$page"; } \
            > "$states/page-$page.lua"
    done
    for tab in $OPTIONS_TABS; do
        { cat "$REPO_ROOT/uitests/pages.lua"; printf '\nFriendlyForeverUIPages.ShowTab("%s")\n' "$tab"; } \
            > "$states/tab-$tab.lua"
    done
    chmod -R a-w "$states"
}

# A clean checkout of $1 at commit $2 in folder $3, checked.
fetch_commit() {
    local repo="$1" commit="$2" dir="$3"
    if [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)" = "$commit" ] \
        && [ -z "$(git -C "$dir" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
        return 0
    fi
    chmod -R u+w "$dir" 2>/dev/null || true
    rm -rf "$dir"
    git init -q "$dir"
    git -C "$dir" fetch -q --depth 1 "$repo" "$commit" || die "Couldn't fetch $repo at $commit."
    if [ $# -gt 3 ]; then git -C "$dir" sparse-checkout set "$4"; fi
    git -C "$dir" checkout -q --detach FETCH_HEAD
    test "$(git -C "$dir" rev-parse HEAD)" = "$commit" || die "$repo isn't at $commit."
}

fetch_sources() {
    say "Fetching the simulator ($SIM_COMMIT) and Forever's UI code ($FOREVER_UI_COMMIT)"
    # Undo the config copy below, so an unchanged checkout is reused.
    git -C "$WORK/sim" checkout -q -- .cargo/config.toml 2>/dev/null || true
    fetch_commit "$SIM_REPO" "$SIM_COMMIT" "$WORK/sim"
    # Published binaries use the release's portable CI config, as in CI.
    cp "$WORK/sim/.cargo/config.ci.toml" "$WORK/sim/.cargo/config.toml"
    grep -q "\"gethe_revision\": \"$FOREVER_UI_COMMIT\"" "$WORK/sim/data/blizzard-ui-builds/wowforever.json" \
        || die "The simulator's Forever UI pin isn't $FOREVER_UI_COMMIT."

    local ui="$WORK/forever-ui"
    fetch_commit "$FOREVER_UI_REPO" "$FOREVER_UI_COMMIT" "$ui" Interface/AddOns
    [ "$(git -C "$ui" show HEAD:version.txt | tr -d '\r\n')" = "$FOREVER_UI_VERSION" ] || die "Forever's UI code isn't version $FOREVER_UI_VERSION."
    # Exactly the files the Forever profile expects, as upstream's image checks.
    git -C "$ui" ls-tree -r --name-only HEAD Interface/AddOns/ | cut -d/ -f3- | LC_ALL=C sort > "$WORK/ui-actual.txt"
    LC_ALL=C sort "$WORK/sim/data/blizzard-ui-files/wowforever.txt" > "$WORK/ui-expected.txt"
    cmp -s "$WORK/ui-expected.txt" "$WORK/ui-actual.txt" \
        || die "Forever's UI code doesn't match the simulator's file list."
    # The markers the simulator's own image writes, so it uses this code and
    # never syncs it from the install or the CDN.
    chmod -R u+w "$ui/Interface/AddOns"
    printf 'profile=wowforever\nversion=%s\nsource=gethe-local-art\ngethe_revision=%s\nfallback=none\n' \
        "$FOREVER_UI_VERSION" "$FOREVER_UI_COMMIT" > "$ui/Interface/AddOns/.wow-ui-sim-blizzard-ui-provenance"
    touch "$ui/Interface/AddOns/.wow-ui-sim-blizzard-ui-complete"
    chmod -R a-w "$ui/Interface/AddOns"
}

build_images() {
    say "Building the build and render images from their pinned bases"
    docker build -q -t "$BUILD_IMAGE" - <<DOCKERFILE >/dev/null
FROM $BUILD_BASE
RUN apt-get update -q && apt-get install -yq --no-install-recommends \
      clang mold git pkg-config cmake libicu-dev \
    && rm -rf /var/lib/apt/lists/*
DOCKERFILE
    docker build -q -t "$RENDER_IMAGE" - <<DOCKERFILE >/dev/null
FROM $RENDER_BASE
RUN apt-get update -q && apt-get install -yq --no-install-recommends \
      libicu72 libegl1 libgl1-mesa-dri libglx-mesa0 mesa-vulkan-drivers fonts-dejavu-core \
    && rm -rf /var/lib/apt/lists/*
DOCKERFILE
}

# Before the long build: that Docker Desktop can mount the install's files.
probe_mounts() {
    say "Checking that Docker can read the install"
    local output
    if ! output="$(docker run --rm --network none --cap-drop ALL --security-opt no-new-privileges --read-only \
        -v "$INSTALL/Data:/wow/Data:ro" -v "$INSTALL/.build.info:/wow/.build.info:ro" \
        -v "$WORK/product-db/.product.db:/wow/.product.db:ro" \
        "$RENDER_IMAGE" test -d /wow/Data/data -a -f /wow/.build.info -a -f /wow/.product.db 2>&1)"; then
        case "$output" in
            *"not shared"* | *"Mounts denied"* | *"mounts denied"*)
                die "Docker Desktop can't see $INSTALL." \
                    "In Docker Desktop: Settings, Resources, File sharing, add \"$INSTALL\", Apply, then try again." ;;
        esac
        die "Docker couldn't read the install's files." "$output"
    fi
}

# The simulator, built in containers as CI builds it, into Docker volumes
# (fast on Docker Desktop; bind mounts are slow there). cargo fetch alone has
# network; the build has none, and the sources are read-only throughout.
build_simulator() {
    say "Downloading the simulator's locked dependencies (network; runs none of their code)"
    docker volume create "$CARGO_VOLUME" >/dev/null
    docker volume create "$TARGET_VOLUME" >/dev/null
    docker run --rm --cap-drop ALL --security-opt no-new-privileges \
        -e HOME=/tmp -e CARGO_HOME=/cargo \
        -v "$WORK/sim:/build:ro" -v "$CARGO_VOLUME:/cargo" -w /build \
        "$BUILD_IMAGE" cargo fetch --locked
    say "Building the simulator for Forever (no network; the first build takes a while)"
    docker run --rm --network none --cap-drop ALL --security-opt no-new-privileges \
        -e HOME=/tmp -e CARGO_HOME=/cargo -e CARGO_TARGET_DIR=/target --pids-limit 8192 \
        -v "$WORK/sim:/build:ro" -v "$CARGO_VOLUME:/cargo:ro" -v "$TARGET_VOLUME:/target" -w /build \
        "$BUILD_IMAGE" cargo build --release --locked --offline --bin wow-sim \
        --no-default-features --features "gui client-wowforever"
}

# One screenshot, in its own container: no network, a read-only root, and
# only a tmpfs and the output's shots/ writable. Killed at its time limit, and
# never left behind.
shoot() {
    local name="$1"; shift
    SHOTS="$SHOTS $name"
    local cid waited=0 poll=5 result
    [ "$SHOT_SECONDS" -ge 10 ] || poll=1
    result="timed out after $SHOT_SECONDS s"
    if ! cid="$(docker run -d --init --label "$LABEL" --network none --cap-drop ALL \
        --security-opt no-new-privileges --read-only --tmpfs /tmp:rw,nosuid,nodev,size=3g \
        --user "$(id -u):$(id -g)" -e HOME=/tmp -e XDG_CACHE_HOME=/tmp/.cache -e XDG_RUNTIME_DIR=/tmp \
        --memory 6g --memory-swap 6g --cpus "$SHOT_CPUS" --pids-limit 4096 \
        -e WOW_SIM_LOAD_OUT_OF_DATE_ADDONS=1 -e WOW_SIM_NO_SAVED_VARS=1 -e WOW_SIM_VERBOSE=1 \
        -e WOW_INSTALL_PATH=/wow -e WOW_PRODUCT="$PRODUCT" \
        -e LIBGL_ALWAYS_SOFTWARE=1 -e WOW_SIM_SOFTWARE_RENDER=1 -e WGPU_BACKEND=gl \
        -v "$TARGET_VOLUME:/target:ro" \
        -v "$WORK/forever-ui/Interface/AddOns:/forever-ui:ro" \
        -v "$INSTALL/Data:/wow/Data:ro" -v "$INSTALL/.build.info:/wow/.build.info:ro" \
        -v "$WORK/product-db/.product.db:/wow/.product.db:ro" \
        -v "$WORK/addons:/test-addons:ro" \
        -v "$WORK/shot-lua:/shot-lua:ro" \
        -v "$OUT/shots:/shots" \
        "$RENDER_IMAGE" sh -c "$LINK_UI" sh --addons-path /test-addons "$@" \
        screenshot --png --width "$WIDTH" --height "$HEIGHT" -o "/shots/sim-$name.png")"; then
        echo "$name: couldn't start its container"
        return 0
    fi
    while [ "$waited" -lt "$SHOT_SECONDS" ]; do
        if [ "$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null)" != "true" ]; then
            result="exited with $(docker inspect -f '{{.State.ExitCode}}' "$cid" 2>/dev/null) after ${waited} s"
            break
        fi
        if [ $((waited % 30)) -eq 0 ]; then
            echo "$name: ${waited} s, $(docker stats --no-stream --format '{{.MemUsage}} cpu {{.CPUPerc}}' "$cid" 2>/dev/null)"
        fi
        sleep "$poll"
        waited=$((waited + poll))
    done
    docker kill "$cid" >/dev/null 2>&1 || true
    docker logs "$cid" > "$OUT/logs/sim-$name.log" 2>&1 || true
    docker rm -f "$cid" >/dev/null 2>&1 || true
    echo "$name: $result"
    # The first shot that's written shows whether the art loads at all.
    if [ -z "${ART_CHECKED:-}" ] && [ -s "$OUT/shots/sim-$name.png" ]; then
        ART_CHECKED=1
        check_first_art "$name"
    fi
}

# Whether a shot's log shows Blizzard's art came from the install: its
# textures (asset-resolver prints "CASC resolver initialized from" once CASC
# opens) and its fonts, FRIZQT among them (the simulator's font loader prints
# "font CASC reader init complete"). Without them the simulator falls back to
# grey boxes and a system font.
textures_loaded() { grep -q "CASC resolver initialized from" "$OUT/logs/sim-$1.log" 2>/dev/null; }
fonts_loaded() { grep -q "font CASC reader init complete" "$OUT/logs/sim-$1.log" 2>/dev/null; }

# The log's first line about CASC failing, as plain printable text: the log
# is the simulator's, so nothing else from it reaches the terminal.
casc_error() {
    { grep -m 1 -E "CASC init failed|CASC open|CASC not available" "$OUT/logs/sim-$1.log" 2>/dev/null || true; } \
        | tr -cd '[:print:]' | cut -c 1-300
}

# Stops the run when the first shot shows no art: the others would only be
# grey boxes too.
check_first_art() {
    textures_loaded "$1" && fonts_loaded "$1" && return 0
    local why
    why="$(casc_error "$1")"
    die "The first shot loaded no Blizzard art from the install (textures: $(yes_no textures_loaded "$1"), fonts: $(yes_no fonts_loaded "$1")), so the rest would be grey boxes. Stopping." \
        "${why:-No CASC error in its log.}" "Its log: $OUT/logs/sim-$1.log"
}

yes_no() { if "$@"; then echo yes; else echo no; fi; }

# The same shots as ui-sim.yml's screenshot job, in the same order (a repo
# test checks this block is the same as CI's).
take_shots() {
    local tab
    shoot game
    # Each tab of the options panel (#112), named after the tab:
    # options-guild-login (the tab the panel opens on), options-buff-thanks...
    for tab in $OPTIONS_TABS; do
        shoot "options-$tab" --exec-lua "@/shot-lua/tab-$tab.lua"
    done
    # The Buff Thanks tab (#101), with the longest "Thank them with" choice.
    shoot options-buff --exec-lua "FriendlyForeverDB.buff.thankStyle = 'both'; SlashCmdList.FRIENDLYFOREVER(''); for _, f in ipairs({ FriendlyForeverOptionsPanel:GetChildren() }) do local c = f.GetScrollChild and f:GetScrollChild(); for _, b in ipairs(c and { c:GetChildren() } or {}) do if b.GetText and b:GetText() == 'Buff Thanks' then b:GetScript('OnClick')(b) end end end"
    # The General page (#35): it doesn't scroll, so everything must fit.
    shoot general --exec-lua "SlashCmdList.FRIENDLYFOREVER(''); Settings.OpenToCategory(FriendlyForeverOptionsPanel.generalPage.category:GetID())"
    # /friendly move shows the buff back button, unlocked, with nobody owed.
    shoot button --exec-lua "SlashCmdList.FRIENDLYFOREVER('move')"
    # A favour owed: someone outside your group buffed you.
    shoot button-favour --exec-lua @/shot-lua/favour.lua
    # Buff mode, with a party member missing your buff.
    shoot button-buffmode --exec-lua @/shot-lua/buffmode.lua
    # The General and Favour Ledger pages, filled with long names and
    # many entries, and the copy window as /friendly export opens it (#52).
    shoot options-general --exec-lua @/shot-lua/page-general.lua
    shoot options-ledger --exec-lua @/shot-lua/page-ledger.lua
    shoot copy-window --exec-lua "SlashCmdList.FRIENDLYFOREVER('export')"
}

# The output folder's layout. Shots write only to shots/, the one folder any
# container mounts; the host writes logs/ and the README, which no container
# sees, so a shot can never make the host write through a link it planted.
# shots/ starts empty, so an earlier run's PNG can't pass for a new one (rm
# -rf removes links without following them).
prepare_output() {
    mkdir -p "$OUT"
    rm -rf "$OUT/shots"
    mkdir -p "$OUT/shots" "$OUT/logs"
    write_readme
}

write_readme() {
    cat > "$OUT/README-simulated.txt" <<'README'
These are SIMULATED screenshots of Friendly Forever: renders by the
wow-ui-sim UI simulator, not screenshots of the game.

They contain Blizzard's art and fonts, read from your own WoW Forever
install. Keep them on this computer: never commit, push, attach to a pull
request or upload them. If you ever show one publicly, label it
"simulated, not a real screenshot". See docs/ui-simulator.md (#139).
README
}

# Every shot's PNG and art, or what's missing.
report() {
    local name missing="" count=0 total=0 textures=0 fonts=0 status=0
    for name in $SHOTS; do
        total=$((total + 1))
        if [ -s "$OUT/shots/sim-$name.png" ]; then count=$((count + 1)); else missing="$missing $name"; fi
        if textures_loaded "$name"; then textures=$((textures + 1)); fi
        if fonts_loaded "$name"; then fonts=$((fonts + 1)); fi
    done
    echo
    say "Blizzard art from the install: textures in $textures of $total shots, fonts (FRIZQT) in $fonts of $total"
    if [ "$textures" -lt "$total" ] || [ "$fonts" -lt "$total" ]; then
        say "Some shots have no Blizzard art."
        status=1
    fi
    if [ -n "$missing" ]; then
        say "$count of $total shots written to $OUT/shots. Missing:$missing"
        status=1
    fi
    if [ "$status" -ne 0 ]; then
        echo "    Each one's log is in $OUT/logs/sim-<name>.log."
        return 1
    fi
    say "Done: all $count shots are in $OUT/shots (logs in $OUT/logs)"
}

main() {
    PRODUCT="$DEFAULT_PRODUCT"
    SIZE="$DEFAULT_SIZE"
    ART_CHECKED=""
    SHOTS=""
    local output="" install="${WOW_INSTALL_PATH:-}" positional=0
    while [ $# -gt 0 ]; do
        case "$1" in
            -h | --help) usage; exit 0 ;;
            --product) [ $# -ge 2 ] || die "--product needs a code."; PRODUCT="$2"; shift ;;
            --product=*) PRODUCT="${1#--product=}" ;;
            --size) [ $# -ge 2 ] || die "--size needs a size, such as 1024x768."; SIZE="$2"; shift ;;
            --size=*) SIZE="${1#--size=}" ;;
            -*) usage >&2; die "Unknown option: $1" ;;
            *)
                positional=$((positional + 1))
                case "$positional" in
                    1) output="$1" ;;
                    2) install="$1" ;;
                    *) usage >&2; die "Too many arguments: $1" ;;
                esac ;;
        esac
        shift
    done

    [ -n "$output" ] || { usage >&2; die "No output folder given."; }
    check_tools
    WORK="${XDG_CACHE_HOME:-$HOME/.cache}/friendlyforever/ui-sim-local-art"
    check_mountable "The working folder's path" "$WORK"
    check_seconds
    check_size
    OPTIONS_TABS="$(options_tabs)"
    resolve_install "$install"
    check_product
    mkdir -p "$WORK"
    WORK="$(real_dir "$WORK")"
    if inside "$WORK" "$REPO_ROOT"; then die "The working folder is inside this repository: $WORK"; fi
    write_product_db
    resolve_output "$output"
    check_docker

    echo "Install:  $INSTALL (product $PRODUCT; only Data/ and .build.info, read-only)"
    echo "Output:   $OUT (shots at ${WIDTH}x${HEIGHT})"
    echo "Working:  $WORK"
    install_traps
    cleanup_containers

    stage_addon
    stage_shot_scripts
    fetch_sources
    build_images
    probe_mounts
    build_simulator
    prepare_output
    say "Taking the screenshots (each one stops after $SHOT_SECONDS s)"
    take_shots
    report
}

# Sourced by spec/ui_sim_local_art_spec.lua to test its parts; run otherwise.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
