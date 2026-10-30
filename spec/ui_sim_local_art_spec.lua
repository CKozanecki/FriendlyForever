-- Spec: #139
-- Checks scripts/ui-sim-local-art.sh, which takes the UI simulator's
-- screenshots with Forever's art from the owner's own install. It can't run
-- here (no install, no Docker daemon), so its pins, shot set and sandbox are
-- checked in its text, and it runs against a stand-in docker that logs every
-- call and plays each shot as told. Nothing here builds, downloads or runs
-- the simulator.
local wow = require("spec.support.wow")

local function shell(command)
    local ok = os.execute(command)
    return ok == true or ok == 0
end

local function quote(text) return "'" .. text:gsub("'", "'\\''") .. "'" end

-- Absolute, so tests can compare it with resolved paths.
local ROOT = (function()
    local p = io.popen("cd " .. quote(wow.ROOT) .. " && pwd -P")
    local root = p:read("*l")
    p:close()
    return root
end)()
local SCRIPT = ROOT .. "/scripts/ui-sim-local-art.sh"

local function write(path, text)
    local file = assert(io.open(path, "wb"))
    file:write(text)
    file:close()
end

local function read(path)
    local file = io.open(path, "rb")
    if not file then return "" end
    local text = file:read("*a")
    file:close()
    return text
end

local function exists(path) return shell("test -e " .. quote(path)) end

local function tempDir()
    local dir = os.tmpname()
    os.remove(dir)
    assert(shell("mkdir -p " .. quote(dir)))
    local p = io.popen("cd " .. quote(dir) .. " && pwd -P")
    dir = p:read("*l")
    p:close()
    return dir
end

-- The script's text without comment-only lines, so prose can't satisfy or
-- trip a check, and with backslash continuations joined.
local function scriptText()
    local kept = {}
    for line in (wow.readFile("scripts/ui-sim-local-art.sh") .. "\n"):gmatch("([^\n]*)\n") do
        if not line:match("^%s*#") then kept[#kept + 1] = line end
    end
    return (table.concat(kept, "\n"):gsub("\\\n%s*", " "))
end

local function workflowText()
    return (wow.readFile(".github/workflows/ui-sim.yml"):gsub("\\\n%s*", " "))
end

-- Each docker run as one line.
local function dockerRuns(text)
    local runs = {}
    for command in text:gmatch("docker run[^\n]*") do runs[#runs + 1] = command end
    return runs
end

-- The lines of text matching pattern, trimmed, in order.
local function linesMatching(text, pattern)
    local found = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        if line:match(pattern) then found[#found + 1] = line:match("^%s*(.-)%s*$") end
    end
    return found
end

-- A stand-in for docker, as pessimistic as real Docker where the script
-- relies on it. It logs each call's arguments, one call a line, to "calls".
-- A detached run (a shot) gets the next container ID, c1, c2 and so on, keeps
-- its --label, and plays what the file behave-<shot> says:
-- - ok (the default): exits 0 after writing its PNG into the folder mounted
--   at /shots;
-- - slow:N: runs for N seconds, then writes its PNG and exits 0;
-- - hang: runs until killed; crash: exits 139; nostart: docker refuses it;
-- - empty: exits 0 after writing an empty PNG;
-- - plant: exits 0 after planting links, to the path in plant-target, in the
--   folder mounted at /shots.
-- Like the real simulator, a shot fails (exit 1, no PNG) when the addon isn't
-- in the folder mounted at /test-addons, or its --exec-lua @/shot-lua/<file>
-- isn't in the folder mounted at /shot-lua. Its state is a file per
-- container: exists-<id>, label-<id>, running-<id> while it runs, start-<id>
-- (when it started) and killed-<id> (seconds from start to a kill while it
-- ran); "sizes" lists each shot's --width x --height. ps honours -a and
-- --filter label=; without -a it lists only running
-- containers. "no-daemon" makes docker info fail, as when Docker Desktop is
-- stopped; "arch" and "ncpu" set the architecture and CPUs it reports. A
-- shot's log shows its art loaded from the install (the simulator's two
-- lines for it), unless log-<shot> holds the log to give instead.
local fakeDocker = [=[#!/bin/bash
dir=$(dirname "$0")
printf '%s\n' "$*" >> "$dir/calls"
command=$1; shift
now() { date +%s; }
finish() { # container, PNG path
  rm -f "$dir/running-$1"; echo 0 > "$dir/exit-$1"; printf '\211PNG\r\n\032\n' > "$2"
}
case "$command" in
  info)
    [ -f "$dir/no-daemon" ] && exit 1
    case "$*" in
      *Architecture*) cat "$dir/arch" 2>/dev/null || echo x86_64 ;;
      *MemTotal*) echo 16000000000 ;;
      *NCPU*) cat "$dir/ncpu" 2>/dev/null || echo 4 ;;
    esac ;;
  run)
    [ "$1" = -d ] || exit 0
    name= shots= lua= addons= label= exec= width= height= previous=
    for arg in "$@"; do
      case "$previous" in
        -o) name=${arg#/shots/sim-}; name=${name%.png} ;;
        --width) width=$arg ;;
        --height) height=$arg ;;
        --label) label=$arg ;;
        --exec-lua) exec=$arg ;;
        -v)
          case "$arg" in
            *:/shots) shots=${arg%:/shots} ;;
            *:/shot-lua:ro) lua=${arg%:/shot-lua:ro} ;;
            *:/test-addons:ro) addons=${arg%:/test-addons:ro} ;;
          esac ;;
      esac
      previous=$arg
    done
    behaviour=$(cat "$dir/behave-$name" 2>/dev/null || echo ok)
    [ "$behaviour" = nostart ] && exit 125
    n=$(( $(cat "$dir/count" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$dir/count"
    cid=c$n
    touch "$dir/exists-$cid"
    printf '%s' "$label" > "$dir/label-$cid"
    printf '%s' "$name" > "$dir/name-$cid"
    echo "$name ${width}x$height" >> "$dir/sizes"
    now > "$dir/start-$cid"
    png="$shots/sim-$name.png"
    if [ ! -f "$addons/FriendlyForever/FriendlyForever.toc" ]; then behaviour=fail; fi
    case "$exec" in
      @/shot-lua/*) [ -f "$lua/${exec#@/shot-lua/}" ] || behaviour=fail ;;
    esac
    case "$behaviour" in
      hang) touch "$dir/running-$cid" ;;
      slow:*) touch "$dir/running-$cid"; echo "$(( $(now) + ${behaviour#slow:} )) $png" > "$dir/slow-$cid" ;;
      crash) echo 139 > "$dir/exit-$cid" ;;
      fail) echo 1 > "$dir/exit-$cid" ;;
      empty) echo 0 > "$dir/exit-$cid"; : > "$png" ;;
      plant)
        echo 0 > "$dir/exit-$cid"
        for link in README-simulated.txt logs; do ln -s "$(cat "$dir/plant-target")" "$shots/$link"; done ;;
      *) finish "$cid" "$png" ;;
    esac
    echo "$cid" ;;
  inspect)
    cid=$3
    if [ -f "$dir/running-$cid" ] && [ -f "$dir/slow-$cid" ]; then
      read -r end png < "$dir/slow-$cid"
      [ "$(now)" -ge "$end" ] && finish "$cid" "$png"
    fi
    case "$2" in
      *Running*) if [ -f "$dir/running-$cid" ]; then echo true; else echo false; fi ;;
      *ExitCode*) cat "$dir/exit-$cid" ;;
    esac ;;
  kill)
    if [ -f "$dir/running-$1" ]; then
      echo $(( $(now) - $(cat "$dir/start-$1") )) > "$dir/killed-$1"
      rm -f "$dir/running-$1"; echo 137 > "$dir/exit-$1"
    fi ;;
  rm)
    for cid; do [ "$cid" = -f ] || rm -f "$dir/exists-$cid" "$dir/running-$cid"; done ;;
  ps)
    all= filter=
    while [ $# -gt 0 ]; do
      case "$1" in
        -a | -aq | -qa) all=1 ;;
        --filter) filter=${2#label=}; shift ;;
      esac
      shift
    done
    for file in "$dir"/exists-*; do
      [ -e "$file" ] || continue
      cid=${file##*/exists-}
      [ -n "$all" ] || [ -f "$dir/running-$cid" ] || continue
      [ -z "$filter" ] || [ "$(cat "$dir/label-$cid" 2>/dev/null)" = "$filter" ] || continue
      echo "$cid"
    done ;;
  logs)
    name=$(cat "$dir/name-$1" 2>/dev/null)
    if [ -f "$dir/log-$name" ]; then cat "$dir/log-$name"
    else printf '[Startup] font FRIZQT__.TTF loaded in 1ms\nCASC resolver initialized from /wow/Data using wowf cache /tmp/x\n'
    fi ;;
  stats) echo "1MiB cpu 1%" ;;
esac
exit 0
]=]

local function fakeBin(files)
    local dir = tempDir()
    assert(shell("mkdir -p " .. quote(dir .. "/bin")))
    write(dir .. "/bin/docker", fakeDocker)
    assert(shell("chmod +x " .. quote(dir .. "/bin/docker")))
    for name, content in pairs(files or {}) do write(dir .. "/bin/" .. name, content) end
    return dir
end

-- A folder laid out like a WoW install, with a WTF/ that must never be
-- mounted. parts leaves out any of its required parts, by name.
local BUILD_KEY = "0123456789abcdef0123456789abcdef"
local INSTALL_KEY = "fedcba9876543210fedcba9876543210"
local BUILD_INFO_HEADER = "Branch!STRING:0|Active!DEC:1|Build Key!HEX:16|CDN Key!HEX:16|Install Key!HEX:16|"
    .. "Version!STRING:0|Product!STRING:0"

-- A .build.info row, in BUILD_INFO_HEADER's columns.
local function buildInfoRow(product, fields)
    fields = fields or {}
    return table.concat({ "us", fields.active or "1", fields.build or BUILD_KEY, "aaaa", fields.install or INSTALL_KEY,
        fields.version or "1.60.1.70532", product }, "|")
end

-- A folder laid out like the owner's shared install: Data/ with the active
-- build's config, .build.info, a WTF/ and a version folder that must never be
-- mounted, and a launcher .product.db the simulator can't decode (as on the
-- owner's Mac, #139), which must never be read. without leaves out any of the
-- parts, by name; rows replaces .build.info's rows.
local function fakeInstall(parent, products, without, rows)
    without = without or {}
    local root = parent .. "/World of Warcraft"
    for _, sub in ipairs({ "Data/data", "Data/config", "Data/indices", "WTF/Account/SECRETNAME", "_forever_" }) do
        if not without[sub] then assert(shell("mkdir -p " .. quote(root .. "/" .. sub))) end
    end
    if not without["Data/config"] and not without["build config"] then
        assert(shell("mkdir -p " .. quote(root .. "/Data/config/01/23")))
        write(root .. "/Data/config/01/23/" .. BUILD_KEY, "# Build Configuration\n")
    end
    if not rows then
        rows = {}
        for _, product in ipairs(products or { "wow", "wowf" }) do rows[#rows + 1] = buildInfoRow(product) end
    end
    table.insert(rows, 1, BUILD_INFO_HEADER)
    if not without[".build.info"] then write(root .. "/.build.info", table.concat(rows, "\n") .. "\n") end
    write(root .. "/.product.db", "\10\7\7\7junk")
    return root
end

describe("Local art screenshots script", function()
    local text

    setup(function() text = scriptText() end)

    describe("its pins", function()
        local function value(source, pattern)
            return source:match("\n%s*" .. pattern .. "(%S+)")
        end

        it("are the simulator commit and base image digests ui-sim.yml pins", function()
            local workflow = workflowText()
            for _, name in ipairs({ "SIM_COMMIT", "BUILD_BASE", "RENDER_BASE" }) do
                local pinned = value(workflow, name .. ": ")
                assert.is_truthy(pinned, "ui-sim.yml has no " .. name)
                assert.are.equal(pinned, value(text, "readonly " .. name .. "="), name .. " differs from ui-sim.yml")
            end
            assert.is_truthy(value(text, "readonly SIM_COMMIT="):match("^" .. ("%x"):rep(40) .. "$"))
            assert.is_truthy(value(text, "readonly BUILD_BASE="):match("^rust@sha256:" .. ("%x"):rep(64) .. "$"))
            assert.is_truthy(value(text, "readonly RENDER_BASE="):match("^debian@sha256:" .. ("%x"):rep(64) .. "$"))
        end)

        it("pin Forever's UI code to a commit, checked against the simulator's own pin", function()
            assert.is_truthy(value(text, "readonly FOREVER_UI_COMMIT="):match("^" .. ("%x"):rep(40) .. "$"),
                "Forever's UI code isn't pinned to a commit")
            assert.is_truthy(text:find('\\"gethe_revision\\": \\"$FOREVER_UI_COMMIT\\"', 1, true),
                "the pin isn't checked against the simulator's wowforever.json")
            assert.is_truthy(text:find("blizzard-ui-files/wowforever.txt", 1, true),
                "the UI code isn't checked against the simulator's file list")
        end)

        it("are used: both sources are checked out at their commits, and both images built from the bases", function()
            assert.is_truthy(text:find('test "$(git -C "$dir" rev-parse HEAD)" = "$commit"', 1, true),
                "a fetched commit isn't checked")
            assert.is_truthy(text:find('fetch_commit "$SIM_REPO" "$SIM_COMMIT"', 1, true))
            assert.is_truthy(text:find('fetch_commit "$FOREVER_UI_REPO" "$FOREVER_UI_COMMIT"', 1, true))
            local bases = {}
            for base in text:gmatch("\nFROM%s+(%S+)") do bases[#bases + 1] = base end
            assert.are.same({ "$BUILD_BASE", "$RENDER_BASE" }, bases)
            for line in text:gmatch("docker build[^\n]*") do
                assert.is_truthy(line:match('^docker build %-q %-t "%$[%u_]+_IMAGE" %- <<DOCKERFILE'),
                    "docker build doesn't build the script's own Dockerfile: " .. line)
            end
        end)

        it("build the simulator for Forever, locked and offline, never from upstream's binaries", function()
            local builds = linesMatching(text, "cargo build")
            assert.are.equal(1, #builds)
            for _, flag in ipairs({ "--locked", "--offline", "--release", '--features "gui client-wowforever"' }) do
                assert.is_truthy(builds[1]:find(flag, 1, true), "the build has no " .. flag)
            end
            for _, banned in ipairs({ "releases/download", "ghcr%.io", "docker pull", "curl", "wget",
                "sync%-blizzard%-ui", "wow%-cli" }) do
                assert.is_falsy(text:find(banned), "the script uses " .. banned)
            end
        end)
    end)

    -- CI's shot block: from the first shot to the copy window's, without
    -- comments, each line trimmed.
    local function shotBlock(source)
        local block = source:match("\n(%s*shoot game\n.-shoot copy%-window[^\n]*)\n")
        assert.is_truthy(block, "no shot block")
        local kept = {}
        for line in (block .. "\n"):gmatch("([^\n]*)\n") do
            if not line:match("^%s*#") and line:match("%S") then kept[#kept + 1] = line:match("^%s*(.-)%s*$") end
        end
        return kept
    end

    it("takes the same shots as ui-sim.yml, at the size asked for (1920×1080 unless told), each named as simulated",
        function()
        local workflow = workflowText()
        local shots = shotBlock(text)
        assert.is_true(#shots >= 9, "expected the screenshot job's shots")
        assert.are.same(shotBlock(workflow), shots)
        -- The scripts the shots run, staged the same way.
        for _, loop in ipairs({ "^%s*for state in ", "^%s*for page in ", "^%s*for tab in " }) do
            assert.are.same(linesMatching(workflow, loop), linesMatching(text, loop))
        end
        assert.is_truthy(text:find("FriendlyForeverUIPages.ShowTab", 1, true), "the tabs' scripts aren't staged")
        assert.is_truthy(text:find('screenshot --png --width "$WIDTH" --height "$HEIGHT" -o "/shots/sim-$name.png"', 1,
            true))
        -- The owner's default (#139): what most players play at.
        assert.is_truthy(text:find("\nreadonly DEFAULT_SIZE=1920x1080\n", 1, true), "the default size isn't 1920x1080")
        -- The tab list is read from ui-sim.yml, not copied.
        assert.is_falsy(text:find("OPTIONS_TABS=[^\"]"), "the tab list is copied into the script")
        assert.is_truthy(text:find('OPTIONS_TABS="$(options_tabs)"', 1, true))
    end)

    it("is never run in CI", function()
        local p = io.popen("grep -rl 'ui-sim-local-art' " .. quote(ROOT .. "/.github") .. " 2>/dev/null")
        local found = p:read("*a")
        p:close()
        assert.are.equal("", found)
    end)

    describe("its sandbox", function()
        it("drops every capability and privilege, with network only to download the locked crates", function()
            local runs, fetches = dockerRuns(text), 0
            assert.is_true(#runs >= 4, "expected the probe, fetch, build and shot docker runs")
            for _, command in ipairs(runs) do
                for _, flag in ipairs({ "--cap-drop ALL", "--security-opt no-new-privileges" }) do
                    assert.is_truthy(command:find(flag, 1, true), "docker run without " .. flag .. ": " .. command)
                end
                for _, banned in ipairs({ "%-%-privileged", "docker%.sock", "%-%-net[%w]*[ =]host", "%-%-pid[ =]",
                    "%-%-ipc", "%-%-userns", "%-%-uts", "%-%-cap%-add", "%-%-device", "unconfined", "%-%-mount",
                    "%-%-volume", "%-%-env%-file", "%-p ", "%-%-publish" }) do
                    assert.is_falsy(command:find(banned), "docker run with " .. banned .. ": " .. command)
                end
                if command:find('"$BUILD_IMAGE" cargo fetch --locked', 1, true) then
                    fetches = fetches + 1
                else
                    assert.is_truthy(command:find("--network none", 1, true), "docker run with network: " .. command)
                end
            end
            assert.are.equal(1, fetches, "expected one dependency download")
        end)

        it("passes no secrets", function()
            for _, command in ipairs(dockerRuns(text)) do
                for name in command:gmatch("%-e%s+([%w_]+)") do
                    for _, word in ipairs({ "KEY", "TOKEN", "SECRET", "PASS", "AUTH", "CRED" }) do
                        assert.is_falsy(name:find(word), "docker run passes " .. name)
                    end
                end
            end
            assert.is_falsy(text:find("CF_API_KEY", 1, true))
        end)

        it("mounts only the install's Data/ and .build.info, read-only, never WTF/ or the launcher's .product.db",
            function()
            local allowed = { ['"$INSTALL/Data:/wow/Data:ro"'] = true,
                ['"$INSTALL/.build.info:/wow/.build.info:ro"'] = true }
            local seen, written = 0, 0
            for _, command in ipairs(dockerRuns(text)) do
                for mount in command:gmatch("%-v%s+(%S+)") do
                    if mount:find("INSTALL", 1, true) then
                        seen = seen + 1
                        assert.is_true(allowed[mount] == true, "mounts the install's " .. mount)
                    end
                    -- The .product.db is the script's own, never the launcher's.
                    if mount:find(":/wow/.product.db", 1, true) then
                        written = written + 1
                        assert.are.equal('"$WORK/product-db/.product.db:/wow/.product.db:ro"', mount)
                    end
                    assert.is_falsy(mount:find("WTF") or mount:find("Interface/AddOns:/wow")
                        or mount:find("^\"?%$INSTALL:"), "mounts " .. mount)
                end
            end
            assert.is_true(seen >= 4, "expected the probe and the shots to mount the install")
            assert.is_true(written >= 2, "expected the probe and the shots to mount the written .product.db")
            assert.is_falsy(text:find("$INSTALL/.product.db", 1, true), "the launcher's .product.db is used")
            assert.is_falsy(text:find("WOW_SIM_WTF_PATH", 1, true) or text:find("WOW_SIM_WOW_PATH", 1, true))
        end)

        it("lets a shot write only to its tmpfs and the output folder, on a read-only root", function()
            local shots = 0
            for _, command in ipairs(dockerRuns(text)) do
                local writable = {}
                for mount in command:gmatch("%-v%s+(%S+)") do
                    if not mount:find(":ro\"?$") then writable[#writable + 1] = mount end
                end
                if command:find("screenshot", 1, true) then
                    shots = shots + 1
                    assert.are.same({ '"$OUT/shots:/shots"' }, writable)
                    assert.is_truthy(command:find("--read-only", 1, true), "a shot's root is writable")
                    for _, cap in ipairs({ "--memory 6g --memory-swap 6g", '--cpus "$SHOT_CPUS"', "--pids-limit 4096",
                        "--init", '--label "$LABEL"' }) do
                        assert.is_truthy(command:find(cap, 1, true), "a shot runs without " .. cap)
                    end
                    assert.is_truthy(command:find("--tmpfs /tmp:", 1, true), "a shot has no tmpfs")
                    assert.is_truthy(command:find("-e HOME=/tmp -e XDG_CACHE_HOME=/tmp/.cache", 1, true),
                        "a shot's cache isn't on its tmpfs")
                elseif command:find("cargo fetch", 1, true) then
                    assert.are.same({ '"$CARGO_VOLUME:/cargo"' }, writable)
                elseif command:find("cargo build", 1, true) then
                    assert.are.same({ '"$TARGET_VOLUME:/target"' }, writable)
                else
                    assert.are.same({}, writable)
                    assert.is_truthy(command:find("--read-only", 1, true), "the probe's root is writable")
                end
            end
            assert.are.equal(1, shots)
        end)

        it("runs only the images it builds from the pinned bases", function()
            local allowed = { run = true, build = true, info = true, ps = true, kill = true, rm = true,
                inspect = true, stats = true, logs = true, volume = true }
            for command in text:gmatch("docker (%l+)") do
                assert.is_true(allowed[command] == true, "the script runs docker " .. command)
            end
            for _, command in ipairs(dockerRuns(text)) do
                assert.is_truthy(command:find('"$BUILD_IMAGE"', 1, true) or command:find('"$RENDER_IMAGE"', 1, true),
                    "docker run of an image that isn't built here: " .. command)
                assert.is_falsy(command:find("@sha256") or command:find("ghcr"), "docker run names an image")
            end
        end)
    end)

    describe("run with bad input", function()
        local dir, bin

        before_each(function()
            dir = tempDir()
            bin = fakeBin()
        end)

        after_each(function()
            os.execute("chmod -R u+w " .. quote(dir) .. " " .. quote(bin) .. " 2>/dev/null")
            os.execute("rm -rf " .. quote(dir) .. " " .. quote(bin))
        end)

        -- Runs the script with the stand-in docker first on PATH and a home of
        -- its own. Returns the exit code, the output and docker's calls.
        local function run(args, env)
            local exports = { "export PATH=" .. quote(bin .. "/bin") .. ':"$PATH"', "export HOME=" .. quote(dir),
                "export XDG_CACHE_HOME=" .. quote(dir .. "/cache"), "unset WOW_INSTALL_PATH UI_SIM_SHOT_SECONDS" }
            for key, value in pairs(env or {}) do exports[#exports + 1] = "export " .. key .. "=" .. quote(value) end
            local quoted = {}
            for _, arg in ipairs(args) do quoted[#quoted + 1] = quote(arg) end
            write(dir .. "/run.sh", table.concat(exports, "\n") .. "\nexec bash " .. quote(SCRIPT) .. " "
                .. table.concat(quoted, " ") .. "\n")
            local p = io.popen("cd " .. quote(dir) .. " && bash run.sh < /dev/null 2>&1; echo \"exit=$?\"")
            local output = p:read("*a")
            p:close()
            local code = tonumber(output:match("exit=(%d+)\n$"))
            return code, output:gsub("exit=%d+\n$", ""), read(bin .. "/bin/calls")
        end

        -- It stopped with message, and called no docker command at all.
        local function refused(message, args, env)
            local code, output, calls = run(args, env)
            assert.are_not.equal(0, code, output)
            assert.is_truthy(output:find(message, 1, true), "expected '" .. message .. "' in:\n" .. output)
            assert.are.equal("", calls, "docker was called")
            return output
        end

        it("stops without an output folder or an install, and never guesses the install", function()
            refused("No output folder given.", {})
            -- A real-looking install where the simulator would look for one.
            fakeInstall(dir, { "wowf" })
            refused("No Forever install given.", { dir .. "/out" })
            assert.is_false(exists(dir .. "/out"))
        end)

        it("stops when the install folder is missing or isn't an install, naming what it lacks", function()
            refused("The Forever install folder doesn't exist", { dir .. "/out", dir .. "/nowhere" })
            for _, part in ipairs({ "Data/data", "Data/config", "Data/indices", ".build.info" }) do
                local parent = dir .. "/" .. part:gsub("[/.]", "_")
                assert(shell("mkdir -p " .. quote(parent)))
                local install = fakeInstall(parent, { "wowf" }, { [part] = true })
                refused("isn't a WoW install: it has no " .. part, { dir .. "/out", install })
            end
            assert.is_false(exists(dir .. "/out"))
        end)

        it("stops when the install has no Forever product, listing the ones it has as plain codes", function()
            local install = fakeInstall(dir, { "wow", "wow_classic", "evil$(touch pwned)" })
            local output = refused("This install has no 'wowf' product", { dir .. "/out", install })
            assert.is_truthy(output:find("Products it lists: wow wow_classic", 1, true), output)
            assert.is_falsy(output:find("evil", 1, true), "printed a product code that isn't plain")
            refused("Products it lists: none", { dir .. "/out", fakeInstall(dir .. "/", {}) })
        end)

        it("stops on a --product that isn't a plain product code", function()
            local install = fakeInstall(dir)
            for _, product in ipairs({ "", "wow f", "wowf;id", "../wowf", "WOWF" }) do
                refused("--product must be a CASC product code", { "--product", product, dir .. "/out", install })
                refused("--product must be a CASC product code", { "--product=" .. product, dir .. "/out", install })
            end
            refused("--product is too long", { "--product", ("a"):rep(33), dir .. "/out", install })
            refused("--product needs a code.", { dir .. "/out", install, "--product" })
        end)

        it("takes another product with --product, in either form, when the install lists it", function()
            local install = fakeInstall(dir, { "wow", "wow_forever" })
            write(bin .. "/bin/no-daemon", "")
            for _, args in ipairs({ { "--product", "wow_forever" }, { "--product=wow_forever" } }) do
                args[#args + 1] = dir .. "/out"
                args[#args + 1] = install
                local code, output = run(args)
                assert.are_not.equal(0, code)
                assert.is_truthy(output:find("Docker isn't running", 1, true), output)
            end
        end)

        it("stops on a --size that isn't WIDTHxHEIGHT from 640x480 to 3840x2160", function()
            local install = fakeInstall(dir)
            for _, size in ipairs({ "", "1024", "1024x", "x768", "1024X768", "1024x768x2", "a x b", "01024x768",
                "1024x0768", "-1x768", "1024 x768", "1024x768;id" }) do
                refused("--size must be WIDTHxHEIGHT in pixels", { "--size", size, dir .. "/out", install })
                refused("--size must be WIDTHxHEIGHT in pixels", { "--size=" .. size, dir .. "/out", install })
            end
            for _, size in ipairs({ "639x480", "640x479", "3841x2160", "3840x2161", "99999x1080", "1920x99999" }) do
                refused("--size must be from 640x480 to 3840x2160", { "--size", size, dir .. "/out", install })
            end
            refused("--size needs a size", { dir .. "/out", install, "--size" })
            -- Too long for the shell's numbers: refused by its length, before
            -- any comparison could fail noisily or wrap around.
            for _, size in ipairs({ ("9"):rep(20) .. "x1080", "1920x" .. ("1"):rep(20) }) do
                local output = refused("--size must be from 640x480 to 3840x2160", { "--size", size, dir .. "/out",
                    install })
                assert.is_falsy(output:find("integer", 1, true), output)
            end
        end)

        it("takes a --size at either end of its range, in either form", function()
            local install = fakeInstall(dir)
            write(bin .. "/bin/no-daemon", "")
            for _, args in ipairs({ { "--size", "640x480" }, { "--size=3840x2160" }, { "--size", "1024x768" } }) do
                args[#args + 1] = dir .. "/out"
                args[#args + 1] = install
                local code, output = run(args)
                assert.are_not.equal(0, code)
                assert.is_truthy(output:find("Docker isn't running", 1, true), output)
            end
        end)

        it("stops on an install path that would change its docker mounts", function()
            for _, name in ipairs({ "a:b", "a\nb" }) do
                local parent = dir .. "/" .. name
                assert(shell("mkdir -p " .. quote(parent)))
                refused("can't contain a colon or a line break", { dir .. "/out", fakeInstall(parent) })
            end
        end)

        it("stops on an output folder inside this repository, or any git repository", function()
            local install = fakeInstall(dir)
            refused("The output folder is inside this repository", { ROOT .. "/sim-shots", install })
            refused("The output folder is inside this repository", { ROOT, install })
            refused("The output folder is inside this repository", { ROOT .. "/docs", install })
            assert.is_false(exists(ROOT .. "/sim-shots"))
            assert(shell("git init -q " .. quote(dir .. "/other-repo")))
            refused("The output folder is inside a git repository", { dir .. "/other-repo/shots", install })
            -- Through a link that leads into the repository.
            assert(shell("ln -s " .. quote(ROOT) .. " " .. quote(dir .. "/link")))
            refused("The output folder is inside this repository", { dir .. "/link/shots", install })
        end)

        it("stops on an output folder it can't use", function()
            local install = fakeInstall(dir)
            refused("The output folder's parent doesn't exist", { dir .. "/no/such/out", install })
            write(dir .. "/file", "")
            refused("The output path isn't a folder", { dir .. "/file", install })
            refused("can't contain a colon", { dir .. "/a:b", install })
            refused("can't contain a colon or a line break", { dir .. "/a\nb", install })
            refused("The output folder is inside the script's working folder",
                { dir .. "/cache/friendlyforever/ui-sim-local-art/out", install })
            refused("The output folder is inside the Forever install", { install .. "/shots", install })
            assert.is_false(exists(dir .. "/a:b"))
        end)

        it("stops on an output folder that holds anything but an earlier run's shots/, logs/ and README", function()
            local install = fakeInstall(dir)
            for _, other in ipairs({ "notes.txt", ".ssh", "Documents", "sim-game.png" }) do
                local out = dir .. "/out-" .. other
                assert(shell("mkdir -p " .. quote(out .. "/logs") .. " " .. quote(out .. "/shots")))
                write(out .. "/README-simulated.txt", "")
                assert(shell("mkdir -p " .. quote(out .. "/" .. other)))
                refused("The output folder holds other files, such as " .. other, { out, install })
            end
            -- The right names, as links elsewhere or the wrong kind of file.
            for _, case in ipairs({ { "shots", "link" }, { "logs", "link" }, { "README-simulated.txt", "link" },
                { "logs", "file" }, { "README-simulated.txt", "folder" }, { "README-simulated.txt", "dangling" } }) do
                local out = dir .. "/out-" .. case[1] .. "-" .. case[2]
                assert(shell("mkdir -p " .. quote(out)))
                if case[2] == "link" then
                    assert(shell("ln -s " .. quote(dir) .. " " .. quote(out .. "/" .. case[1])))
                elseif case[2] == "dangling" then
                    -- Writing the README through it would create its target.
                    assert(shell("ln -s " .. quote(dir .. "/planted") .. " " .. quote(out .. "/" .. case[1])))
                elseif case[2] == "file" then
                    write(out .. "/" .. case[1], "")
                else
                    assert(shell("mkdir " .. quote(out .. "/" .. case[1])))
                end
                refused("The output folder holds other files, such as " .. case[1], { out, install })
            end
            assert.is_false(exists(dir .. "/planted"))
        end)

        it("takes an output folder an earlier run made, then goes on to check Docker", function()
            local install = fakeInstall(dir)
            local out = dir .. "/out"
            assert(shell("mkdir -p " .. quote(out .. "/logs") .. " " .. quote(out .. "/shots")))
            write(out .. "/shots/sim-game.png", "")
            write(out .. "/README-simulated.txt", "")
            write(bin .. "/bin/no-daemon", "")
            local code, output, calls = run({ out, install })
            assert.are_not.equal(0, code)
            assert.is_truthy(output:find("Docker isn't running", 1, true), output)
            assert.are.equal("info\n", calls)
        end)

        it("stops on unknown options, extra arguments and a bad time limit", function()
            local install = fakeInstall(dir)
            refused("Unknown option: --network", { "--network", "host", dir .. "/out", install })
            refused("Too many arguments", { dir .. "/out", install, "extra" })
            for _, seconds in ipairs({ "abc", "0", "010", "-5", "3601", "1 0" }) do
                refused("UI_SIM_SHOT_SECONDS", { dir .. "/out", install }, { UI_SIM_SHOT_SECONDS = seconds })
            end
        end)

        it("takes the install from WOW_INSTALL_PATH, then stops when Docker isn't running, taking no shots", function()
            local install = fakeInstall(dir)
            write(bin .. "/bin/no-daemon", "")
            local code, output, calls = run({ dir .. "/out" }, { WOW_INSTALL_PATH = install })
            assert.are_not.equal(0, code)
            assert.is_truthy(output:find("Docker isn't running", 1, true), output)
            assert.are.equal("info\n", calls)
            assert.is_false(exists(dir .. "/out"))
        end)

        it("stops when its working folder would be inside this repository", function()
            -- Removed even if the check fails, so nothing is left in the repository.
            finally(function() os.execute("rm -rf " .. quote(ROOT .. "/.cache-test")) end)
            refused("The working folder is inside this repository", { dir .. "/out", fakeInstall(dir) },
                { XDG_CACHE_HOME = ROOT .. "/.cache-test" })
        end)

        it("gives each shot at most 3 CPUs, and no more than Docker has", function()
            for ncpu, expected in pairs({ ["8"] = "3", ["3"] = "3", ["2"] = "2", ["1"] = "1", ["0"] = "1", x = "1" }) do
                write(bin .. "/bin/ncpu", ncpu .. "\n")
                write(dir .. "/cpus.sh", "export PATH=" .. quote(bin .. "/bin") .. ':"$PATH"\nsource ' .. quote(SCRIPT)
                    .. "\ncheck_docker > /dev/null\necho \"$SHOT_CPUS\"\n")
                local p = io.popen("bash " .. quote(dir .. "/cpus.sh") .. " 2>&1")
                assert.are.equal(expected .. "\n", p:read("*a"), "with " .. ncpu .. " CPUs")
                p:close()
            end
        end)

        it("runs its steps in order: an earlier run's containers go before anything is staged or shot", function()
            local install = fakeInstall(dir)
            write(bin .. "/bin/exists-old1", "")
            write(bin .. "/bin/running-old1", "")
            write(bin .. "/bin/label-old1", "friendlyforever.ui-sim-local-art")
            -- Every step that builds, fetches or shoots logs its name instead.
            local steps = { "stage_addon", "stage_shot_scripts", "fetch_sources", "build_images", "probe_mounts",
                "build_simulator", "take_shots" }
            local stubs = {}
            for _, step in ipairs(steps) do
                stubs[#stubs + 1] = step .. "() { echo " .. step .. " >> " .. quote(dir .. "/steps")
                    .. "; ls " .. quote(bin .. "/bin") .. " | grep -cE '^(exists|running)-old1$' >> " .. quote(dir .. "/steps") .. " || true; }"
            end
            write(dir .. "/main.sh", table.concat({
                "export PATH=" .. quote(bin .. "/bin") .. ':"$PATH" HOME=' .. quote(dir) .. " XDG_CACHE_HOME="
                    .. quote(dir .. "/cache"),
                "unset WOW_INSTALL_PATH UI_SIM_SHOT_SECONDS",
                "source " .. quote(SCRIPT),
                table.concat(stubs, "\n"),
                "main " .. quote(dir .. "/out") .. " " .. quote(install),
            }, "\n") .. "\n")
            local p = io.popen("bash " .. quote(dir .. "/main.sh") .. " < /dev/null 2>&1; echo \"exit=$?\"")
            local output = p:read("*a")
            p:close()
            assert.is_truthy(output:find("Done: all 0 shots", 1, true), output)
            assert.is_truthy(output:find("(shots at 1920x1080)", 1, true), output)
            local log = {}
            for line in read(dir .. "/steps"):gmatch("[^\n]+") do log[#log + 1] = line end
            local expected = {}
            for _, step in ipairs(steps) do
                expected[#expected + 1] = step
                expected[#expected + 1] = "0"
            end
            assert.are.same(expected, log)
            -- Its own files are in place, written by the host.
            assert.is_true(shell("test -f " .. quote(dir .. "/out/README-simulated.txt") .. " && test -d "
                .. quote(dir .. "/out/shots") .. " && test -d " .. quote(dir .. "/out/logs")))
        end)

        it("stops on Docker for another architecture than the pinned images'", function()
            local install = fakeInstall(dir)
            write(bin .. "/bin/arch", "aarch64\n")
            local code, output, calls = run({ dir .. "/out", install })
            assert.are_not.equal(0, code)
            assert.is_truthy(output:find("Intel (x86_64)", 1, true), output)
            assert.is_falsy(calls:find("run", 1, true) or calls:find("build", 1, true), calls)
        end)
    end)

    describe("options tabs", function()
        -- Runs options_tabs against a ui-sim.yml holding workflow.
        local function tabs(workflow)
            local dir = tempDir()
            assert(shell("mkdir -p " .. quote(dir .. "/.github/workflows")))
            write(dir .. "/.github/workflows/ui-sim.yml", workflow)
            write(dir .. "/run.sh", "source " .. quote(SCRIPT) .. "\nREPO_ROOT=" .. quote(dir) .. "\noptions_tabs\n")
            local p = io.popen("bash " .. quote(dir .. "/run.sh") .. " < /dev/null 2>&1; echo \"exit=$?\"")
            local output = p:read("*a")
            p:close()
            os.execute("rm -rf " .. quote(dir))
            return tonumber(output:match("exit=(%d+)\n$")), output:gsub("exit=%d+\n$", "")
        end

        it("are ui-sim.yml's own list", function()
            local code, output = tabs(wow.readFile(".github/workflows/ui-sim.yml"))
            assert.are.equal(0, code, output)
            local listed = wow.readFile(".github/workflows/ui-sim.yml"):match("\n%s*OPTIONS_TABS: ([^\n]+)")
            assert.are.equal(listed .. "\n", output)
        end)

        it("stop the script when the list is missing or holds a name that isn't plain", function()
            local code, output = tabs("jobs:\n")
            assert.are_not.equal(0, code)
            assert.is_truthy(output:find("ui-sim.yml has no OPTIONS_TABS list.", 1, true), output)
            for _, bad in ipairs({ "a $(id)", "a;b", "../x", "Tab", "a*" }) do
                code, output = tabs("      OPTIONS_TABS: guild-login " .. bad .. "\n")
                assert.are_not.equal(0, code, bad)
                assert.is_truthy(output:find("has a name that isn't plain", 1, true), output)
            end
        end)
    end)

    describe("its own .product.db", function()
        local dir

        before_each(function() dir = tempDir() end)
        after_each(function() os.execute("chmod -R u+w " .. quote(dir) .. "; rm -rf " .. quote(dir)) end)

        -- Reads a protobuf message into its fields, in order, as { field,
        -- value } (a number for a varint, a string for anything
        -- length-delimited). Strict: any other wire type, or bytes left over,
        -- is an error. Written here from the protobuf spec, not from the
        -- script, so the script's encoding is checked independently.
        local function decode(bytes)
            local fields, at = {}, 1
            local function varint()
                local value, scale = 0, 1
                while true do
                    local b = assert(bytes:byte(at), "a varint runs past the end")
                    at = at + 1
                    value = value + (b % 128) * scale
                    if b < 128 then return value end
                    scale = scale * 128
                end
            end
            while at <= #bytes do
                local key = varint()
                local field, wire = math.floor(key / 8), key % 8
                if wire == 0 then
                    fields[#fields + 1] = { field, varint() }
                elseif wire == 2 then
                    local length = varint()
                    assert(at + length - 1 <= #bytes, "a field runs past the end")
                    fields[#fields + 1] = { field, bytes:sub(at, at + length - 1) }
                    at = at + length
                else
                    error("wire type " .. wire)
                end
            end
            return fields
        end

        -- What the simulator's decoder (cascette-rs product_db.rs) would
        -- read: each product's code, version, build key and install key.
        local function products(bytes)
            local list = {}
            for _, install in ipairs(decode(bytes)) do
                assert.are.equal(1, install[1], "Database holds something other than product_install")
                local entry = {}
                for _, f in ipairs(decode(install[2])) do
                    if f[1] == 2 then entry.code = f[2] end
                    if f[1] == 4 then
                        for _, state in ipairs(decode(f[2])) do
                            assert.are.equal(1, state[1])
                            for _, base in ipairs(decode(state[2])) do
                                local name = ({ [7] = "version", [14] = "build", [16] = "install" })[base[1]]
                                assert.is_truthy(name, "unexpected field " .. base[1])
                                entry[name] = base[2]
                            end
                        end
                    end
                end
                list[#list + 1] = entry
            end
            return list
        end

        -- Runs write_product_db for the install at root.
        local function writeDb(root, product)
            write(dir .. "/db.sh", table.concat({
                "source " .. quote(SCRIPT),
                "INSTALL=" .. quote(root) .. " PRODUCT=" .. (product or "wowf") .. " WORK=" .. quote(dir .. "/work"),
                "write_product_db",
            }, "\n") .. "\n")
            local p = io.popen("bash " .. quote(dir .. "/db.sh") .. " < /dev/null 2>&1; echo \"exit=$?\"")
            local output = p:read("*a")
            p:close()
            return tonumber(output:match("exit=(%d+)\n$")), output, dir .. "/work/product-db/.product.db"
        end

        it("holds the product's active build from .build.info, as the simulator's decoder reads it", function()
            local root = fakeInstall(dir, nil, nil, { buildInfoRow("wow", { build = ("b"):rep(32) }),
                buildInfoRow("wowf", { active = "0", build = ("c"):rep(32) }), buildInfoRow("wowf") })
            local code, output, file = writeDb(root)
            assert.are.equal(0, code, output)
            assert.is_truthy(output:find("Build:    wowf 1.60.1.70532, build config " .. BUILD_KEY, 1, true), output)
            assert.are.same({ { code = "wowf", version = "1.60.1.70532", build = BUILD_KEY, install = INSTALL_KEY } },
                products(read(file)))
            -- Read-only, by mode.
            local p = io.popen("find " .. quote(dir .. "/work/product-db") .. " -perm -u=w")
            assert.are.equal("", p:read("*a"))
            p:close()
        end)

        it("leaves out an install key the install doesn't have, and takes long versions and other products", function()
            for _, case in ipairs({
                { rows = { buildInfoRow("wowf", { install = "" }) }, want = {}, noInstall = true },
                { rows = { buildInfoRow("wowf", { version = ("9."):rep(32) }) }, want = { version = ("9."):rep(32) } },
                { rows = { buildInfoRow("wow_forever") }, product = "wow_forever", want = { code = "wow_forever" } },
            }) do
                local root = fakeInstall(dir, nil, nil, case.rows)
                local code, output, file = writeDb(root, case.product)
                assert.are.equal(0, code, output)
                local entry = products(read(file))[1]
                local expected = { code = case.product or "wowf", version = "1.60.1.70532", build = BUILD_KEY,
                    install = INSTALL_KEY }
                for key, value in pairs(case.want) do expected[key] = value end
                if case.noInstall then expected.install = nil end
                assert.are.same(expected, entry)
                os.execute("chmod -R u+w " .. quote(dir) .. "; rm -rf " .. quote(dir) .. "/*")
            end
        end)

        it("stops, writing nothing, unless the product has one readable active build with its config", function()
            for _, case in ipairs({
                { rows = { buildInfoRow("wowf", { active = "0" }) }, message = "has 0 active 'wowf' builds" },
                { rows = { buildInfoRow("wowf"), buildInfoRow("wowf") }, message = "has 2 active 'wowf' builds" },
                { rows = { buildInfoRow("wow") }, message = "has 0 active 'wowf' builds" },
                { rows = { buildInfoRow("wowf", { build = ("a"):rep(31) }) }, message = "build key isn't one" },
                { rows = { buildInfoRow("wowf", { build = ("A"):rep(32) }) }, message = "build key isn't one" },
                { rows = { buildInfoRow("wowf", { build = ("g"):rep(32) }) }, message = "build key isn't one" },
                { rows = { buildInfoRow("wowf", { install = "abc" }) }, message = "install key isn't one" },
                { rows = { buildInfoRow("wowf", { version = "" }) }, message = "version isn't one" },
                { rows = { buildInfoRow("wowf", { version = "1.60 $(id)" }) }, message = "version isn't one" },
                { rows = { buildInfoRow("wowf", { version = ("1"):rep(65) }) }, message = "version isn't one" },
                { rows = { buildInfoRow("wowf") }, without = { ["build config"] = true },
                    message = "has no build config for its active 'wowf' build" },
            }) do
                local root = fakeInstall(dir, nil, case.without, case.rows)
                local code, output, file = writeDb(root)
                assert.are_not.equal(0, code, output)
                assert.is_truthy(output:find(case.message, 1, true), output)
                assert.is_false(exists(file), "a .product.db was written")
                os.execute("chmod -R u+w " .. quote(dir) .. "; rm -rf " .. quote(dir) .. "/*")
            end
        end)

        it("is written before Docker is used, and a bad build stops the script with no docker call", function()
            local bin = fakeBin()
            local root = fakeInstall(dir, nil, nil, { buildInfoRow("wowf", { active = "0" }) })
            write(dir .. "/run.sh", "export PATH=" .. quote(bin .. "/bin") .. ':"$PATH" HOME=' .. quote(dir)
                .. " XDG_CACHE_HOME=" .. quote(dir .. "/cache") .. "\nexec bash " .. quote(SCRIPT) .. " "
                .. quote(dir .. "/out") .. " " .. quote(root) .. "\n")
            local p = io.popen("bash " .. quote(dir .. "/run.sh") .. " < /dev/null 2>&1; echo \"exit=$?\"")
            local output = p:read("*a")
            p:close()
            assert.is_truthy(output:find("has 0 active 'wowf' builds", 1, true), output)
            assert.are.equal("", read(bin .. "/bin/calls"))
            os.execute("rm -rf " .. quote(bin))
        end)
    end)

    describe("checkouts", function()
        local dir

        before_each(function() dir = tempDir() end)
        after_each(function() os.execute("chmod -R u+w " .. quote(dir) .. "; rm -rf " .. quote(dir)) end)

        -- Runs fetch_commit from a local repository, so nothing downloads.
        local function fetch(commit)
            write(dir .. "/fetch.sh", "source " .. quote(SCRIPT) .. "\nfetch_commit " .. quote(dir .. "/origin") .. " "
                .. commit .. " " .. quote(dir .. "/copy") .. "\n")
            local p = io.popen("bash " .. quote(dir .. "/fetch.sh") .. " < /dev/null 2>&1; echo \"exit=$?\"")
            local output = p:read("*a")
            p:close()
            return tonumber(output:match("exit=(%d+)\n$")), output
        end

        it("are fetched at their commit, kept when clean, and fetched again when changed", function()
            assert(shell("mkdir -p " .. quote(dir .. "/origin")))
            write(dir .. "/origin/file", "pinned\n")
            assert(shell("cd " .. quote(dir .. "/origin") .. " && git init -q && git add -A && git -c user.name=t "
                .. "-c user.email=t@t commit -qm pin"))
            local p = io.popen("git -C " .. quote(dir .. "/origin") .. " rev-parse HEAD")
            local commit = p:read("*l")
            p:close()
            local code, output = fetch(commit)
            assert.are.equal(0, code, output)
            assert.are.equal("pinned\n", read(dir .. "/copy/file"))
            -- Kept: an untracked file the script added survives.
            write(dir .. "/copy/marker", "")
            assert.are.equal(0, (fetch(commit)))
            assert.is_true(exists(dir .. "/copy/marker"))
            -- Changed: fetched again, the change gone.
            write(dir .. "/copy/file", "tampered\n")
            code, output = fetch(commit)
            assert.are.equal(0, code, output)
            assert.are.equal("pinned\n", read(dir .. "/copy/file"))
            -- A commit the source doesn't have stops the script.
            code, output = fetch(("0"):rep(40))
            assert.are_not.equal(0, code)
            assert.is_truthy(output:find("Couldn't fetch", 1, true), output)
        end)
    end)

    describe("Forever's UI code", function()
        local dir

        -- A simulator checkout with its Forever pin and file list, and a
        -- checkout of the UI code at commit, holding files.
        before_each(function()
            dir = tempDir()
        end)

        after_each(function()
            os.execute("chmod -R u+w " .. quote(dir) .. " 2>/dev/null")
            os.execute("rm -rf " .. quote(dir))
        end)

        -- Sets up the two checkouts, then runs fetch_sources with fetching
        -- itself replaced, since nothing here may download.
        local function check(options)
            local sim, ui = dir .. "/work/sim", dir .. "/work/forever-ui"
            assert(shell("mkdir -p " .. quote(sim .. "/.cargo") .. " " .. quote(sim .. "/data/blizzard-ui-builds")
                .. " " .. quote(sim .. "/data/blizzard-ui-files") .. " " .. quote(ui .. "/Interface/AddOns/Blizzard_A")))
            write(sim .. "/.cargo/config.ci.toml", "[build]\n")
            write(sim .. "/data/blizzard-ui-builds/wowforever.json", '{\n  "version": "1.60.1.70532",\n'
                .. '  "gethe_revision": "' .. (options.pin or "ca8368f2f2380cbe696854f7f2646387c278a61b") .. '"\n}\n')
            write(sim .. "/data/blizzard-ui-files/wowforever.txt", options.list or "Blizzard_A/A.lua\nBlizzard_A/A.toc\n")
            write(ui .. "/Interface/AddOns/Blizzard_A/A.lua", "")
            write(ui .. "/Interface/AddOns/Blizzard_A/A.toc", "")
            write(ui .. "/version.txt", (options.version or "1.60.1.70532") .. "\r\n")
            assert(shell("cd " .. quote(ui) .. " && git init -q && git add -A && git -c user.name=t -c user.email=t@t "
                .. "commit -qm ui"))
            write(dir .. "/run.sh", table.concat({
                "source " .. quote(SCRIPT),
                "WORK=" .. quote(dir .. "/work"),
                "fetch_commit() { :; }",
                "fetch_sources",
            }, "\n") .. "\n")
            local p = io.popen("bash " .. quote(dir .. "/run.sh") .. " < /dev/null 2>&1; echo \"exit=$?\"")
            local output = p:read("*a")
            p:close()
            return tonumber(output:match("exit=(%d+)\n$")), output, ui .. "/Interface/AddOns/"
        end

        it("is marked complete when it's the pinned version with exactly the simulator's files", function()
            local code, output, addons = check({})
            assert.are.equal(0, code, output)
            assert.is_true(exists(addons .. ".wow-ui-sim-blizzard-ui-complete"))
            assert.is_truthy(read(addons .. ".wow-ui-sim-blizzard-ui-provenance")
                :find("gethe_revision=ca8368f2f2380cbe696854f7f2646387c278a61b\n", 1, true))
            -- By its mode, which holds for root too.
            local p = io.popen("find " .. quote(addons) .. " -perm -u=w")
            assert.are.equal("", p:read("*a"), "the UI code is left writable")
            p:close()
        end)

        it("stops, unmarked, on a different pin, version or file list", function()
            for _, case in ipairs({
                { options = { pin = ("0"):rep(40) }, message = "Forever UI pin isn't" },
                { options = { version = "1.60.2.1" }, message = "isn't version 1.60.1.70532" },
                { options = { list = "Blizzard_A/A.lua\n" }, message = "doesn't match the simulator's file list" },
                { options = { list = "Blizzard_A/A.lua\nBlizzard_A/A.toc\nBlizzard_B/B.lua\n" },
                    message = "doesn't match the simulator's file list" },
            }) do
                local code, output, addons = check(case.options)
                assert.are_not.equal(0, code, output)
                assert.is_truthy(output:find(case.message, 1, true), output)
                assert.is_false(exists(addons .. ".wow-ui-sim-blizzard-ui-complete"))
                os.execute("chmod -R u+w " .. quote(dir) .. "; rm -rf " .. quote(dir .. "/work"))
            end
        end)
    end)

    describe("shots", function()
        local dir, bin

        before_each(function()
            dir = tempDir()
            bin = fakeBin()
            assert(shell("mkdir -p " .. quote(dir .. "/out")))
        end)

        after_each(function()
            os.execute("chmod -R u+w " .. quote(dir) .. " 2>/dev/null; rm -rf " .. quote(dir) .. " " .. quote(bin))
        end)

        -- Sources the script (which then runs nothing by itself) with the
        -- stand-in docker, and runs body with the settings main would make.
        local function source(body, behaviours, seconds, size)
            for name, behaviour in pairs(behaviours or {}) do write(bin .. "/bin/behave-" .. name, behaviour) end
            write(dir .. "/run.sh", table.concat({
                "export PATH=" .. quote(bin .. "/bin") .. ':"$PATH"',
                "export UI_SIM_SHOT_SECONDS=" .. (seconds or "2"),
                "source " .. quote(SCRIPT),
                'OPTIONS_TABS="$(options_tabs)" SHOTS="" ART_CHECKED=""',
                "OUT=" .. quote(dir .. "/out") .. " WORK=" .. quote(dir .. "/work") .. " INSTALL=" .. quote(dir .. "/wow")
                    .. " PRODUCT=wowf SHOT_CPUS=1 SIZE=" .. (size or "1920x1080") .. " && check_size",
                -- The addon and the shots' scripts, as main stages them.
                "mkdir -p " .. quote(dir .. "/work") .. " && stage_addon > /dev/null && stage_shot_scripts",
                body,
            }, "\n") .. "\n")
            local p = io.popen("bash " .. quote(dir .. "/run.sh") .. " < /dev/null 2>&1; echo \"exit=$?\"")
            local output = p:read("*a")
            p:close()
            local code = tonumber(output:match("exit=(%d+)\n$"))
            return code, output:gsub("exit=%d+\n$", ""), read(bin .. "/bin/calls")
        end

        -- The shots CI takes, in its order, with ui-sim.yml's tabs.
        local function expectedShots()
            local tabs = wow.readFile(".github/workflows/ui-sim.yml"):match("\n%s*OPTIONS_TABS: ([^\n]+)")
            local list = { "game" }
            for tab in tabs:gmatch("%S+") do list[#list + 1] = "options-" .. tab end
            for _, name in ipairs({ "options-buff", "general", "button", "button-favour", "button-buffmode",
                "options-general", "options-ledger", "copy-window" }) do
                list[#list + 1] = name
            end
            return list
        end

        -- A shot's container ID: c1 for the first, and so on.
        local function cidOf(name)
            for i, shot in ipairs(expectedShots()) do
                if shot == name then return "c" .. i end
            end
        end

        local function leftovers()
            local p = io.popen("ls " .. quote(bin .. "/bin") .. " | grep -E '^(exists|running)-' || true")
            local found = p:read("*a")
            p:close()
            return found
        end

        local function startedShots(calls)
            local names = {}
            for name in calls:gmatch("run %-d [^\n]- %-o /shots/sim%-([%w-]+)%.png\n") do names[#names + 1] = name end
            return names
        end

        it("writes every shot, named as simulated, with its log, and reports them all", function()
            local code, output, calls = source("prepare_output; take_shots; report")
            assert.are.equal(0, code, output)
            local expected = expectedShots()
            assert.is_true(#expected >= 16, "expected CI's shots, a tab each")
            assert.are.same(expected, startedShots(calls))
            for _, name in ipairs(expected) do
                assert.is_true(exists(dir .. "/out/shots/sim-" .. name .. ".png"), name)
                assert.is_true(exists(dir .. "/out/logs/sim-" .. name .. ".log"), name)
            end
            assert.is_truthy(output:find("Done: all " .. #expected .. " shots are in", 1, true), output)
            assert.are.equal("", leftovers())
        end)

        it("kills a shot that hangs at its time limit, and still takes the others, leaving no container", function()
            local started, total = os.time(), #expectedShots()
            local code, output, calls = source("prepare_output; take_shots; report",
                { ["options-guild-login"] = "hang", ["options-buff"] = "empty", button = "crash",
                    ["copy-window"] = "hang" })
            assert.is_true(os.time() - started < 40, "the shots took too long")
            assert.are_not.equal(0, code)
            assert.are.equal(total, #startedShots(calls), "a failed shot stopped the others")
            assert.is_truthy(output:find("options-guild-login: timed out after 2 s", 1, true), output)
            assert.is_truthy(output:find("copy-window: timed out after 2 s", 1, true), output)
            assert.is_truthy(output:find("button: exited with 139", 1, true), output)
            assert.is_truthy(output:find("game: exited with 0", 1, true), output)
            -- The hung ones were killed, and every container removed.
            assert.is_truthy(calls:find("\nkill " .. cidOf("options-guild-login") .. "\n", 1, true), calls)
            assert.is_truthy(calls:find("\nkill " .. cidOf("copy-window") .. "\n", 1, true), calls)
            for n = 1, total do assert.is_truthy(calls:find("\nrm %-f c" .. n .. "\n"), "c" .. n .. " wasn't removed") end
            assert.are.equal("", leftovers())
            -- An empty PNG doesn't count as written.
            assert.is_truthy(output:find((total - 4) .. " of " .. total .. " shots written to", 1, true), output)
            assert.is_truthy(output:find("Missing: options-guild-login options-buff button copy-window\n", 1, true),
                output)
        end)

        -- From the stand-in's own clock: when each shot started, and how long
        -- after that it was killed (nil if it never was while running).
        local function killedAfter(name)
            local seconds = read(bin .. "/bin/killed-" .. cidOf(name))
            return tonumber(seconds:match("%d+"))
        end

        it("gives every shot its whole time limit, and kills a hung one soon after it", function()
            local code, output = source("prepare_output; take_shots; report",
                { game = "slow:2", ["options-guild-login"] = "hang" }, "4")
            assert.are_not.equal(0, code)
            -- Slower than a poll, faster than the limit: written, never killed.
            assert.is_nil(killedAfter("game"), "a shot within its limit was killed")
            assert.is_true(exists(dir .. "/out/shots/sim-game.png"), output)
            assert.is_truthy(output:find("game: exited with 0 after", 1, true), output)
            -- The hung one: killed no sooner than the limit, and within two
            -- seconds of it.
            local after = killedAfter("options-guild-login")
            assert.is_truthy(after, "the hung shot was never killed")
            assert.is_true(after >= 4 and after <= 6, "killed after " .. after .. " s, with a 4 s limit")
            assert.are.equal("", leftovers())
        end)

        it("stages the addon and every shot's script exactly as ui-sim.yml does", function()
            -- ui-sim.yml's own staging step, run as CI runs it.
            local yml = wow.readFile(".github/workflows/ui-sim.yml")
            local step = yml:match("%- name: Stage the screenshot scripts\n%s*run: |\n(.-)\n%s*%- name:")
            assert.is_truthy(step, "no staging step in ui-sim.yml")
            local indent = #step:match("^( *)")
            local lines = {}
            for line in (step .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line:sub(indent + 1) end
            local tabs = yml:match("\n%s*OPTIONS_TABS: ([^\n]+)")
            write(dir .. "/ci.sh", "export RUNNER_TEMP=" .. quote(dir .. "/ci") .. " OPTIONS_TABS=" .. quote(tabs)
                .. "\nmkdir -p \"$RUNNER_TEMP\"\n" .. table.concat(lines, "\n") .. "\n")
            assert(shell("cd " .. quote(ROOT) .. " && bash -eo pipefail " .. quote(dir .. "/ci.sh")))
            local code, output = source("ls -R " .. quote(dir .. "/work/addons") .. " > " .. quote(dir .. "/addons.txt"))
            assert.are.equal(0, code, output)
            assert.is_true(shell("diff -r " .. quote(dir .. "/ci/shot-lua") .. " " .. quote(dir .. "/work/shot-lua")),
                "the shots' scripts differ from CI's")
            -- The packaged addon, read-only, where the shots mount it.
            assert.is_true(exists(dir .. "/work/addons/FriendlyForever/FriendlyForever.toc"))
            local p = io.popen("find " .. quote(dir .. "/work/addons") .. " " .. quote(dir .. "/work/shot-lua")
                .. " -perm -u=w")
            assert.are.equal("", p:read("*a"), "staged files are left writable")
            p:close()
        end)

        -- The owner's first run, as its logs read (#139): CASC never opened,
        -- and the fonts fell back to a system one.
        local NO_CASC = "[Startup] font CASC reader init begin\n"
            .. "CASC init failed: read installed WoW product: product wowf in /wow/.product.db: invalid protobuf\n"
            .. "[Startup] font FRIZQT__.TTF loaded in 2ms\n"
            .. "[Startup] font system fallback loaded in 40ms\n"
            .. "asset-cache extraction failed: fdid 1: CASC not available\n"
        -- Textures from the install, and fonts that fell back.
        local NO_FONTS = "[Startup] font FRIZQT__.TTF loaded in 2ms\n[Startup] font system fallback loaded in 40ms\n"
            .. "CASC resolver initialized from /wow/Data using wowf\n"

        it("reports where every shot's textures and fonts came from", function()
            local code, output = source("prepare_output; take_shots; report")
            assert.are.equal(0, code, output)
            local total = #expectedShots()
            assert.is_truthy(output:find("Blizzard art from the install: textures in " .. total .. " of " .. total
                .. " shots, fonts (FRIZQT) in " .. total .. " of " .. total, 1, true), output)
        end)

        it("stops after the first shot written when it loaded no Blizzard art, saying why", function()
            -- The owner's first run (#139): CASC never opened, so every shot was grey.
            write(bin .. "/bin/log-game", NO_CASC)
            local code, output, calls = source("install_traps; prepare_output; take_shots; report")
            assert.are_not.equal(0, code)
            assert.are.same({ "game" }, startedShots(calls), "it went on after the first shot")
            assert.is_truthy(output:find("The first shot loaded no Blizzard art from the install (textures: no, "
                .. "fonts: no)", 1, true), output)
            assert.is_truthy(output:find("CASC init failed: read installed WoW product", 1, true), output)
            assert.are.equal("", leftovers())
        end)

        it("checks the first shot that's written, and stops when only its fonts are missing", function()
            write(bin .. "/bin/log-options-guild-login", NO_FONTS)
            local code, output, calls = source("prepare_output; take_shots; report", { game = "crash" })
            assert.are_not.equal(0, code)
            assert.are.same({ "game", "options-guild-login" }, startedShots(calls))
            assert.is_truthy(output:find("(textures: yes, fonts: no)", 1, true), output)
        end)

        it("stops when the first shot has its fonts but no textures", function()
            write(bin .. "/bin/log-game", "[Startup] font FRIZQT__.TTF loaded in 1ms\n")
            local code, output, calls = source("prepare_output; take_shots; report")
            assert.are_not.equal(0, code)
            assert.are.same({ "game" }, startedShots(calls))
            assert.is_truthy(output:find("(textures: no, fonts: yes)", 1, true), output)
        end)

        it("fails the run when a later shot has its textures but not its fonts", function()
            write(bin .. "/bin/log-button", NO_FONTS)
            local code, output = source("prepare_output; take_shots; report")
            assert.are_not.equal(0, code)
            local total = #expectedShots()
            assert.is_truthy(output:find("textures in " .. total .. " of " .. total .. " shots, fonts (FRIZQT) in "
                .. (total - 1) .. " of " .. total, 1, true), output)
            assert.is_truthy(output:find("Some shots have no Blizzard art.", 1, true), output)
        end)

        it("counts fonts from the font loader's own lines, as a working run's cold cache prints them", function()
            -- A working first shot (#139 review): the font reader can't open in
            -- a cold cache, so its "init complete" line never comes, but the
            -- fonts load through CASC, with no fallback.
            write(bin .. "/bin/log-game", "[Startup] font CASC reader init begin\n"
                .. "[Startup] font FRIZQT__.TTF loaded in 900ms\n[Startup] font FRIZQT___CYR.TTF loaded in 3ms\n"
                .. "CASC resolver initialized from /wow/Data using wowf cache /tmp/.cache/x\n")
            local code, output = source("prepare_output; take_shots; report")
            assert.are.equal(0, code, output)
            -- No sign the fonts were loaded at all counts as no fonts.
            write(bin .. "/bin/log-game", "CASC resolver initialized from /wow/Data using wowf\n"
                .. "[Startup] font FRIZQT___CYR.TTF loaded in 3ms\n")
            code, output = source("prepare_output; take_shots; report")
            assert.are_not.equal(0, code)
            assert.is_truthy(output:find("(textures: yes, fonts: no)", 1, true), output)
        end)

        it("prints only plain text from a shot's log", function()
            write(bin .. "/bin/log-game", "\27]0;title\7\27[31mCASC init failed: \27[2Jbad\n")
            local code, output = source("prepare_output; take_shots; report")
            assert.are_not.equal(0, code)
            assert.is_truthy(output:find("CASC init failed: bad", 1, true) or output:find("CASC init failed:", 1, true),
                output)
            assert.is_falsy(output:find("\27", 1, true), "an escape from the log reached the terminal")
            assert.is_falsy(output:find("\7", 1, true), "a control character from the log reached the terminal")
        end)

        it("fails the run when a later shot has no Blizzard art", function()
            write(bin .. "/bin/log-copy-window", NO_CASC)
            local code, output, calls = source("prepare_output; take_shots; report")
            assert.are_not.equal(0, code)
            local total = #expectedShots()
            assert.are.equal(total, #startedShots(calls))
            assert.is_truthy(output:find("textures in " .. (total - 1) .. " of " .. total .. " shots, fonts (FRIZQT) in "
                .. (total - 1) .. " of " .. total, 1, true), output)
            assert.is_truthy(output:find("Some shots have no Blizzard art.", 1, true), output)
            assert.is_falsy(output:find("Done:", 1, true), output)
        end)

        it("takes every shot at 1920×1080, or at the size asked for", function()
            for _, case in ipairs({ { nil, "1920x1080" }, { "1024x768", "1024x768" }, { "2560x1440", "2560x1440" } }) do
                os.remove(bin .. "/bin/sizes")
                os.execute("rm -f " .. quote(bin .. "/bin") .. "/count")
                local code, output = source("prepare_output; take_shots; report", nil, nil, case[1])
                assert.are.equal(0, code, output)
                local sizes, count = read(bin .. "/bin/sizes"), 0
                for name, size in sizes:gmatch("(%S+) (%S+)\n") do
                    count = count + 1
                    assert.are.equal(case[2], size, name)
                end
                assert.are.equal(#expectedShots(), count)
            end
        end)

        it("carries on when docker refuses to start a shot", function()
            local code, output, calls = source("prepare_output; take_shots; report", { general = "nostart" })
            assert.are_not.equal(0, code)
            assert.is_truthy(output:find("general: couldn't start its container", 1, true), output)
            assert.are.equal(#expectedShots(), #startedShots(calls), "a shot wasn't tried")
            for _, name in ipairs({ "game", "options-buff", "button", "copy-window" }) do
                assert.is_true(exists(dir .. "/out/shots/sim-" .. name .. ".png"), name)
            end
            assert.is_truthy(output:find("Missing: general", 1, true), output)
        end)

        it("never writes through links a shot plants, and never counts an earlier run's PNG", function()
            local target = dir .. "/target"
            write(target, "the owner's file\n")
            write(bin .. "/bin/plant-target", target)
            -- An earlier run's shot that this run fails to take.
            assert(shell("mkdir -p " .. quote(dir .. "/out/shots")))
            write(dir .. "/out/shots/sim-general.png", "old")
            local code, output = source("prepare_output; take_shots; report", { game = "plant", general = "crash" })
            assert.are_not.equal(0, code)
            assert.are.equal("the owner's file\n", read(target), "the host wrote through a planted link")
            -- The host's own files are real files, outside what shots can write.
            assert.is_true(shell("test -f " .. quote(dir .. "/out/README-simulated.txt") .. " && test ! -L "
                .. quote(dir .. "/out/README-simulated.txt")))
            assert.is_true(shell("test -f " .. quote(dir .. "/out/logs/sim-copy-window.log") .. " && test ! -L "
                .. quote(dir .. "/out/logs")))
            -- game planted links instead of its PNG; general's old one isn't counted.
            assert.is_truthy(output:find("Missing: game general\n", 1, true), output)
        end)

        it("leaves no container running when stopped partway", function()
            -- Stopped (as by Ctrl-C) while a shot hangs.
            local code, _, calls = source("install_traps; prepare_output; (sleep 1; kill -TERM $$) & take_shots",
                { game = "hang" }, "60")
            assert.are.equal(130, code)
            assert.is_truthy(calls:find("\nkill c1\n", 1, true), calls)
            assert.are.equal("", leftovers())
        end)

        it("removes the containers an earlier run left behind, running or not, and no others", function()
            -- old1 still runs, old2 has exited, mine is the owner's own.
            for cid, state in pairs({ old1 = "running", old2 = "exited", mine = "running" }) do
                write(bin .. "/bin/exists-" .. cid, "")
                write(bin .. "/bin/label-" .. cid, cid == "mine" and "" or "friendlyforever.ui-sim-local-art")
                if state == "running" then write(bin .. "/bin/running-" .. cid, "") end
            end
            local code = source("cleanup_containers")
            assert.are.equal(0, code)
            assert.are.equal("exists-mine\nrunning-mine\n", leftovers())
        end)
    end)
end)
