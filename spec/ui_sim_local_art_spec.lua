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

-- A stand-in for docker. It logs each call's arguments, one call a line, to
-- "calls". A detached run (a shot) gets the next container ID, c1, c2 and so
-- on, and plays what the file behave-<shot> says: hang (runs until killed),
-- crash (exits 139), nostart (docker refuses it), plant (exits 0 after
-- planting links, to the path in plant-target, in the folder mounted at
-- /shots) or, by default, ok (exits 0 after writing a PNG into that folder). Its state is a
-- file per container: exists-<id>, and running-<id> while it runs.
-- "no-daemon" makes docker info fail, as when Docker Desktop is stopped;
-- "arch" sets the architecture it reports.
local fakeDocker = [=[#!/bin/bash
dir=$(dirname "$0")
printf '%s\n' "$*" >> "$dir/calls"
command=$1; shift
case "$command" in
  info)
    [ -f "$dir/no-daemon" ] && exit 1
    case "$*" in
      *Architecture*) cat "$dir/arch" 2>/dev/null || echo x86_64 ;;
      *MemTotal*) echo 16000000000 ;;
      *NCPU*) echo 4 ;;
    esac ;;
  run)
    [ "$1" = -d ] || exit 0
    name= shots= previous=
    for arg in "$@"; do
      case "$previous" in
        -o) name=${arg#/shots/sim-}; name=${name%.png} ;;
        -v) case "$arg" in *:/shots) shots=${arg%:/shots} ;; esac ;;
      esac
      previous=$arg
    done
    behaviour=$(cat "$dir/behave-$name" 2>/dev/null || echo ok)
    [ "$behaviour" = nostart ] && exit 125
    n=$(( $(cat "$dir/count" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$dir/count"
    cid=c$n
    touch "$dir/exists-$cid"
    case "$behaviour" in
      hang) touch "$dir/running-$cid" ;;
      crash) echo 139 > "$dir/exit-$cid" ;;
      plant)
        echo 0 > "$dir/exit-$cid"
        for link in README-simulated.txt logs; do ln -s "$(cat "$dir/plant-target")" "$shots/$link"; done ;;
      *) echo 0 > "$dir/exit-$cid"; printf '\211PNG\r\n\032\n' > "$shots/sim-$name.png" ;;
    esac
    echo "$cid" ;;
  inspect)
    cid=$3
    case "$2" in
      *Running*) if [ -f "$dir/running-$cid" ]; then echo true; else echo false; fi ;;
      *ExitCode*) cat "$dir/exit-$cid" ;;
    esac ;;
  kill)
    if [ -f "$dir/running-$1" ]; then rm -f "$dir/running-$1"; echo 137 > "$dir/exit-$1"; fi ;;
  rm)
    for cid; do rm -f "$dir/exists-$cid" "$dir/running-$cid"; done ;;
  ps)
    for file in "$dir"/exists-*; do [ -e "$file" ] && echo "${file##*/exists-}"; done ;;
  logs) echo "log of $1" ;;
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
local function fakeInstall(parent, products, without)
    without = without or {}
    local root = parent .. "/World of Warcraft"
    for _, sub in ipairs({ "Data/data", "Data/config", "Data/indices", "WTF/Account/SECRETNAME", "_classic_beta_" }) do
        if not without[sub] then assert(shell("mkdir -p " .. quote(root .. "/" .. sub))) end
    end
    local rows = { "Branch!STRING:0|Active!DEC:1|Build Key!HEX:16|Version!STRING:0|Product!STRING:0" }
    for _, product in ipairs(products or { "wow", "wowf" }) do
        rows[#rows + 1] = "us|1|0123456789abcdef0123456789abcdef|1.60.1.70532|" .. product
    end
    if not without[".build.info"] then write(root .. "/.build.info", table.concat(rows, "\n") .. "\n") end
    if not without[".product.db"] then write(root .. "/.product.db", "\10\4wowf") end
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

    it("takes the same shots as ui-sim.yml, at 1024×768, each named as simulated", function()
        local workflow = workflowText()
        local shots = shotBlock(text)
        assert.is_true(#shots >= 9, "expected the screenshot job's shots")
        assert.are.same(shotBlock(workflow), shots)
        -- The scripts the shots run, staged the same way.
        for _, loop in ipairs({ "^%s*for state in ", "^%s*for page in ", "^%s*for tab in " }) do
            assert.are.same(linesMatching(workflow, loop), linesMatching(text, loop))
        end
        assert.is_truthy(text:find("FriendlyForeverUIPages.ShowTab", 1, true), "the tabs' scripts aren't staged")
        assert.is_truthy(text:find('screenshot --png --width 1024 --height 768 -o "/shots/sim-$name.png"', 1, true))
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

        it("mounts only the install's Data/, .build.info and .product.db, read-only, and never WTF/", function()
            local allowed = { ['"$INSTALL/Data:/wow/Data:ro"'] = true,
                ['"$INSTALL/.build.info:/wow/.build.info:ro"'] = true,
                ['"$INSTALL/.product.db:/wow/.product.db:ro"'] = true }
            local seen = 0
            for _, command in ipairs(dockerRuns(text)) do
                for mount in command:gmatch("%-v%s+(%S+)") do
                    if mount:find("INSTALL", 1, true) then
                        seen = seen + 1
                        assert.is_true(allowed[mount] == true, "mounts the install's " .. mount)
                    end
                    assert.is_falsy(mount:find("WTF") or mount:find("Interface/AddOns:/wow")
                        or mount:find("^\"?%$INSTALL:"), "mounts " .. mount)
                end
            end
            assert.is_true(seen >= 6, "expected the probe and the shots to mount the install")
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
            for _, part in ipairs({ "Data/data", "Data/config", "Data/indices", ".build.info", ".product.db" }) do
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
            for _, product in ipairs({ "", "wow f", "wowf;id", "../wowf", "WOWF", ("a"):rep(33) }) do
                refused("--product", { "--product", product, dir .. "/out", install })
            end
            refused("--product needs a code.", { dir .. "/out", install, "--product" })
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
                { "logs", "file" }, { "README-simulated.txt", "folder" } }) do
                local out = dir .. "/out-" .. case[1] .. "-" .. case[2]
                assert(shell("mkdir -p " .. quote(out)))
                if case[2] == "link" then
                    assert(shell("ln -s " .. quote(dir) .. " " .. quote(out .. "/" .. case[1])))
                elseif case[2] == "file" then
                    write(out .. "/" .. case[1], "")
                else
                    assert(shell("mkdir " .. quote(out .. "/" .. case[1])))
                end
                refused("The output folder holds other files, such as " .. case[1], { out, install })
            end
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
            os.execute("rm -rf " .. quote(dir) .. " " .. quote(bin))
        end)

        -- Sources the script (which then runs nothing by itself) with the
        -- stand-in docker, and runs body with the settings main would make.
        local function source(body, behaviours, seconds)
            for name, behaviour in pairs(behaviours or {}) do write(bin .. "/bin/behave-" .. name, behaviour) end
            write(dir .. "/run.sh", table.concat({
                "export PATH=" .. quote(bin .. "/bin") .. ':"$PATH"',
                "export UI_SIM_SHOT_SECONDS=" .. (seconds or "2"),
                "source " .. quote(SCRIPT),
                'OPTIONS_TABS="$(options_tabs)" SHOTS=""',
                "OUT=" .. quote(dir .. "/out") .. " WORK=" .. quote(dir .. "/work") .. " INSTALL=" .. quote(dir .. "/wow")
                    .. " PRODUCT=wowf SHOT_CPUS=1",
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
                { ["options-guild-login"] = "hang", button = "crash", ["copy-window"] = "hang" })
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
            assert.is_truthy(output:find((total - 3) .. " of " .. total .. " shots written to", 1, true), output)
            assert.is_truthy(output:find("Missing: options-guild-login button copy-window", 1, true), output)
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

        it("removes containers an earlier run left behind", function()
            for _, cid in ipairs({ "old1", "old2" }) do
                write(bin .. "/bin/exists-" .. cid, "")
                write(bin .. "/bin/running-" .. cid, "")
            end
            local code = source("cleanup_containers")
            assert.are.equal(0, code)
            assert.are.equal("", leftovers())
        end)
    end)
end)
