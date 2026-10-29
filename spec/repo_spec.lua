-- Spec: #49, #65, #77, #80, #82, #89, #95, #103, #104, #106, #117, #118, #119, #122, #127
-- Checks the GitHub workflows, the CurseForge packager config and the release
-- scripts. Mistakes here only show up on GitHub or after a release ships, so
-- they're caught here instead.
local wow = require("spec.support.wow")

local function splitLines(text)
    local list = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        list[#list + 1] = (line:gsub("\r$", ""))
    end
    return list
end

local function lines(path) return splitLines(wow.readFile(path)) end

local function indentOf(line) return #line:match("^( *)") end
local function isBlank(line) return line:match("^%s*$") or line:match("^%s*#") end

-- Workflow text without comment-only lines, so prose can't satisfy or trip a check.
local function withoutComments(text)
    local kept = {}
    for _, line in ipairs(splitLines(text)) do
        if not line:match("^%s*#") then kept[#kept + 1] = line end
    end
    return table.concat(kept, "\n")
end

-- Splits workflow text into jobs, each with its full text, its job-level keys
-- and its steps in order. Works from indentation, so any consistent YAML
-- indent is fine.
local function parseText(text)
    local jobs, order = {}, {}
    local inJobs, jobIndent, job = false, nil, nil
    local stepsKey, stepIndent, step

    for _, line in ipairs(splitLines(withoutComments(text))) do
        if not inJobs then
            inJobs = line:match("^jobs:%s*$") ~= nil
        elseif not isBlank(line) then
            local indent = indentOf(line)
            jobIndent = jobIndent or indent
            if indent < jobIndent then break end
            local name = indent == jobIndent and line:match("^%s*([%w_-]+):%s*$")
            if name then
                job = { name = name, text = "", steps = {}, keys = {} }
                jobs[name], order[#order + 1] = job, job
                stepsKey, stepIndent, step = nil, nil, nil
            elseif job then
                job.keyIndent = job.keyIndent or indent
                if indent == job.keyIndent then
                    local k = line:match("^%s*([%w_-]+):")
                    if k then job.keys[k] = true end
                end
                local item = line:match("^%s*%- ") and (stepIndent or indent) == indent
                if stepsKey and indent <= stepsKey and not item then
                    stepsKey, step = nil, nil
                end
                local key = line:match("^(%s*)steps:%s*$")
                if key then
                    stepsKey, stepIndent = #key, nil
                elseif stepsKey and item and indent >= stepsKey then
                    stepIndent = indent
                    step = { text = "" }
                    job.steps[#job.steps + 1] = step
                end
                if step then step.text = step.text .. line .. "\n" end
            end
        end
        if job then job.text = job.text .. line .. "\n" end
    end
    return jobs, order
end

local function parseWorkflow(path) return parseText(wow.readFile(path)) end

local function indexOf(steps, pattern)
    for i, step in ipairs(steps) do
        if step.text:find(pattern) then return i end
    end
end

local function workflowFiles()
    local list, p = {}, io.popen('ls "' .. wow.ROOT .. '.github/workflows"')
    for name in p:read("*a"):gmatch("[^\n]+") do
        if name:match("%.ya?ml$") then list[#list + 1] = ".github/workflows/" .. name end
    end
    p:close()
    assert.is_true(#list > 0, "no workflows found")
    return list
end

local function jobWith(order, pattern)
    for _, job in ipairs(order) do
        if job.text:find(pattern) then return job end
    end
end

describe("Workflow parser", function()
    it("finds jobs and steps at any indent", function()
        local jobs, order = parseText("on: push\njobs:\n    a:\n        steps:\n        - run: one\n"
            .. "        - name: two\n          run: x\n    b:\n        needs: a\n        env:\n          X: 1\n"
            .. "        steps:\n            -   run: three\n              env:\n                Y: 2\n")

        assert.are.equal(2, #order)
        assert.are.equal(2, #jobs.a.steps)
        assert.is_truthy(jobs.a.steps[2].text:find("run: x", 1, true))
        assert.are.equal(1, #jobs.b.steps)
        assert.is_truthy(jobs.b.keys.needs and jobs.b.keys.env and jobs.b.keys.steps)
        assert.is_falsy(jobs.a.keys.env)
    end)
end)

describe("Workflows", function()
    it("pin every action to a full commit SHA", function()
        for _, path in ipairs(workflowFiles()) do
            for _, line in ipairs(lines(path)) do
                local ref = line:match("^%s*%-?%s*uses:%s*[\"']?([^%s#\"']+)")
                if ref then
                    local sha = ref:match("@(%x+)$")
                    assert.is_truthy(sha and #sha == 40, path .. ": " .. ref .. " is not pinned to a commit SHA")
                end
            end
        end
    end)

    it("never keep the checkout token in .git/config", function()
        for _, path in ipairs(workflowFiles()) do
            for _, job in ipairs(select(2, parseWorkflow(path))) do
                for _, step in ipairs(job.steps) do
                    if step.text:find("actions/checkout@") then
                        assert.is_truthy(step.text:find("persist%-credentials:%s*false"),
                            path .. " job " .. job.name .. " checks out without persist-credentials: false")
                    end
                end
            end
        end
    end)

    it("keep secrets and blanket write access out of workflow-level settings", function()
        for _, path in ipairs(workflowFiles()) do
            local text = withoutComments(wow.readFile(path))
            local header = text:match("^(.-)\njobs:") or text
            assert.is_falsy(header:find("secrets%."), path .. " exposes secrets to every job")
            assert.is_falsy(text:find("write%-all"), path .. " grants write-all")
        end
    end)

    it("install the readline headers before building Lua, in the same job", function()
        local found = 0
        for _, path in ipairs(workflowFiles()) do
            for _, job in ipairs(select(2, parseWorkflow(path))) do
                local setup = indexOf(job.steps, "make setup")
                if setup then
                    found = found + 1
                    local headers = indexOf(job.steps, "libreadline%-dev")
                    assert.is_truthy(headers and headers < setup,
                        path .. " job " .. job.name .. " builds Lua before installing libreadline-dev")
                end
            end
        end
        assert.is_true(found > 0, "no job runs make setup")
    end)
end)

describe("CI workflow", function()
    local path = ".github/workflows/ci.yml"

    it("checks pull requests with lint, tests and packaging", function()
        local ci = wow.readFile(path)
        assert.is_truthy(ci:find("\n  pull_request:"), "CI does not run on pull requests")
        for _, target in ipairs({ "make lint", "make test", "make package" }) do
            assert.is_truthy(ci:find(target, 1, true), "CI never runs " .. target)
        end
    end)

    it("builds with the release packager, without uploading, and compares it with package.sh", function()
        local _, order = parseWorkflow(path)
        local job = jobWith(order, "BigWigsMods/packager@")
        assert.is_truthy(job, "CI never runs the release packager")
        assert.is_falsy(job.text:find("secrets%."), "CI's packager build must not see secrets")

        local packager = indexOf(job.steps, "BigWigsMods/packager@")
        assert.is_truthy(job.steps[packager].text:find("args:%s*%-d"), "CI's packager run would upload")
        local notes, package = indexOf(job.steps, "make release%-notes"), indexOf(job.steps, "make package")
        local compare = indexOf(job.steps, "compare%-packages%.sh")
        assert.is_truthy(notes and notes < packager, "release notes aren't written before the packager runs")
        assert.is_truthy(package and compare and compare > packager and compare > package,
            "CI doesn't compare the two packages after building both")
    end)
    -- #103: the tools come from scripts/dev-setup.sh, so a change to it or to
    -- its checksums must miss the cache, and a cache hit still runs the
    -- script, which checks the install and downloads nothing.
    it("installs the tools through make setup, keyed on the setup script and its checksums", function()
        local _, order = parseWorkflow(path)
        local job = jobWith(order, "make test")
        local setup = indexOf(job.steps, "make setup")
        assert.is_truthy(setup and setup < indexOf(job.steps, "make test"), "CI tests without make setup")
        assert.is_falsy(job.steps[setup].text:find("if:", 1, true), "a cache hit skips make setup")
        assert.is_falsy(job.text:find("continue%-on%-error"), "a failed make setup doesn't stop the job")
        local cache = indexOf(job.steps, "actions/cache@")
        assert.is_truthy(cache and cache < setup, "the tools aren't cached before make setup")
        local key = job.steps[cache].text:match("key:%s*([^\n]+)")
        for _, file in ipairs({ "Makefile", "scripts/dev-setup.sh", "scripts/dev-setup.lock" }) do
            assert.is_truthy(key and key:find("'" .. file .. "'", 1, true), "the cache key doesn't cover " .. file)
        end
    end)
end)

describe("UI simulator workflow", function()
    local path = ".github/workflows/ui-sim.yml"
    local text, jobs, order

    setup(function()
        text = withoutComments(wow.readFile(path))
        jobs, order = parseWorkflow(path)
    end)

    -- Each docker run as one line, its backslash continuations joined.
    local function dockerRuns(job)
        local runs = {}
        for command in (job.text:gsub("\\\n%s*", " ")):gmatch("docker run[^\n]*") do
            runs[#runs + 1] = command
        end
        return runs
    end

    it("defaults to read-only access, with no secrets", function()
        local header = text:match("^(.-)\njobs:")
        assert.is_truthy(header, "no jobs found")
        -- contents: read, and nothing else under permissions (the next line
        -- that isn't blank isn't indented).
        assert.is_truthy((header .. "\nend"):find("\npermissions:\n  contents: read\n\n*[^%s]"),
            "the default access isn't read-only")
        assert.is_falsy(header:find("write"), "the workflow grants write access to every job")
        assert.is_falsy(text:find("secrets%."), path .. " uses secrets")
    end)

    it("never fails CI: every job is report only", function()
        assert.is_true(#order >= 3, "expected the scenario, screenshot and publish jobs")
        for _, job in ipairs(order) do
            -- The job's own key: a step's continue-on-error doesn't cover the job.
            local key = "\n" .. (" "):rep(job.keyIndent) .. "continue%-on%-error:%s*true"
            assert.is_truthy(job.text:find(key), job.name .. " can fail CI")
        end
    end)

    it("pins the image, the sources and the render base exactly", function()
        local function pinned(prefix, digits)
            return text:find("\n%s*" .. prefix .. ("%x"):rep(digits) .. "%s") ~= nil
        end
        assert.is_true(pinned("IMAGE: ghcr%.io/osso/wow%-ui%-sim@sha256:", 64), "the simulator image isn't pinned by digest")
        assert.is_true(pinned("SIM_COMMIT: ", 40), "the simulator source isn't pinned to a commit")
        assert.is_true(pinned("BLIZZARD_UI_COMMIT: ", 40), "Blizzard's UI isn't pinned to a commit")
        assert.is_true(pinned("BUILD_BASE: rust@sha256:", 64), "the build image's base isn't pinned by digest")
        assert.is_true(pinned("RENDER_BASE: debian@sha256:", 64), "the render image's base isn't pinned by digest")
        assert.is_falsy(text:lower():find("uses:%s*osso/"), "uses the simulator project's own Action")

        -- The pins are used: every image built starts from one of them, and
        -- the fetched sources are checked against theirs.
        local bases = {}
        for base in text:gmatch("\n%s*FROM%s+(%S+)") do bases[#bases + 1] = base end
        assert.are.same({ "$BUILD_BASE", "$RENDER_BASE" }, bases)
        assert.is_truthy(text:find('rev-parse HEAD)" = "$SIM_COMMIT"', 1, true), "the simulator's commit isn't checked")
        assert.is_truthy(text:find('rev-parse HEAD)" = "$BLIZZARD_UI_COMMIT"', 1, true), "Blizzard's commit isn't checked")
    end)

    -- Only cargo fetch gets network, to download the locked crates; it runs
    -- none of their code. Everything else that runs the simulator's code
    -- (its build scripts, macros and the simulator) has none.
    it("sandboxes every container: no capabilities, read-only sources, network only to download crates", function()
        local found, fetches, builds = 0, 0, 0
        for _, job in ipairs(order) do
            for _, command in ipairs(dockerRuns(job)) do
                found = found + 1
                local fetch = command:find("ff%-build cargo fetch %-%-locked%s*$") ~= nil
                for _, flag in ipairs({ "--cap-drop ALL", "--security-opt no-new-privileges" }) do
                    assert.is_truthy(command:find(flag, 1, true), job.name .. ": docker run without " .. flag)
                end
                -- Ways out of the sandbox. Mounts are only ever -v, so the
                -- check below sees them all.
                for _, banned in ipairs({ "%-%-privileged", "docker%.sock", "%-%-net[%w]*[ =]host", "%-%-pid[ =]",
                    "%-%-ipc", "%-%-userns", "%-%-uts", "%-%-cap%-add", "%-%-device", "unconfined", "%-%-mount",
                    "%-%-volume" }) do
                    assert.is_falsy(command:find(banned), job.name .. ": docker run with " .. banned)
                end
                if fetch then
                    fetches = fetches + 1
                else
                    assert.is_truthy(command:find("--network none", 1, true), job.name .. ": docker run with network")
                end
                if command:find("cargo build", 1, true) then
                    builds = builds + 1
                    assert.is_truthy(command:find("--offline", 1, true), "the simulator build may download")
                end
                for mount in command:gmatch("%-v%s+(%S+)") do
                    local writable = mount:find(":/shots\"?$") or mount:find(":/target\"?$")
                        or (fetch and mount:find(":/cargo\"?$"))
                    assert.is_truthy(mount:find(":ro\"?$") or writable, job.name .. ": " .. mount .. " is mounted writable")
                end
            end
        end
        assert.is_true(found >= 5, "expected the simulator's docker runs")
        assert.are.equal(1, fetches, "expected one dependency download")
        assert.are.equal(1, builds, "expected the simulator to be built in a container")
        -- Anywhere outside a docker run, cargo would run on the runner.
        local outside = text:gsub("\\\n%s*", " "):gsub("docker run[^\n]*", "")
        assert.is_falsy(outside:find("%f[%w]cargo%s"), "cargo runs on the runner, outside a container")
    end)

    -- Containers only ever run the pinned image or the two images built here
    -- from the pinned bases, and nothing builds the simulator's own Dockerfile
    -- (that would run its build scripts on the runner's Docker, with network).
    it("runs only the pinned image and the images it builds from the pinned bases", function()
        local allowed = { run = true, build = true, pull = true, inspect = true, stats = true, logs = true,
            kill = true, rm = true, top = true }
        for command in text:gmatch("docker (%l+)") do
            assert.is_true(allowed[command] == true, "the workflow runs docker " .. command)
        end
        local built = {}
        for line in text:gmatch("docker build[^\n]*") do
            local name = line:match("^docker build %-t (ff%-%l+) %- <<DOCKERFILE%s*$")
            assert.is_truthy(name, "docker build doesn't build the workflow's own Dockerfile: " .. line)
            built[#built + 1] = name
        end
        assert.are.same({ "ff-build", "ff-render" }, built)
        for pull in text:gmatch("docker pull[^\n]*") do
            assert.are.equal('docker pull "$IMAGE"', pull)
        end
        for _, job in ipairs(order) do
            for _, command in ipairs(dockerRuns(job)) do
                local image = command:find('%s"%$IMAGE"%s') or command:find("%sff%-build%s") or command:find("%sff%-render%s")
                assert.is_truthy(image, job.name .. ": docker run of an image that isn't pinned: " .. command)
                assert.is_falsy(command:find("ghcr%.io") or command:find("@sha256"), job.name .. ": docker run names an image")
            end
        end
    end)

    it("lets only the publish job write, and it runs nothing from the simulator or the pull request", function()
        for _, job in ipairs(order) do
            if job.name ~= "publish-screenshots" then
                assert.is_falsy(job.text:find("write"), job.name .. " asks for write access")
            end
        end
        local publish = jobs["publish-screenshots"]
        assert.is_truthy(publish, "no publish-screenshots job")
        assert.is_truthy(publish.text:find("github%.event%.pull_request%.head%.repo%.full_name == github%.repository"),
            "the publish job runs for pull requests from forks")
        for action in publish.text:gmatch("uses:%s*([^@%s]+)") do
            assert.are.equal("actions/download-artifact", action, "the publish job uses " .. action)
        end
        for _, banned in ipairs({ "docker", "cargo", "make ", "wow%-sim", "%./", "%f[%w]bash%s", "%f[%w]sh%s",
            "source " }) do
            assert.is_falsy(publish.text:find(banned), "the publish job runs " .. banned)
        end
        assert.is_truthy(publish.text:find("89504e470d0a1a0a", 1, true), "the publish job doesn't check for PNGs")
    end)
end)

describe("UI screenshots clean-up workflow", function()
    local path = ".github/workflows/ui-screenshots-cleanup.yml"
    local text, header, jobs, order

    setup(function()
        text = withoutComments(wow.readFile(path))
        header = text:match("^(.-)\njobs:")
        jobs, order = parseWorkflow(path)
    end)

    -- A step's run: | block, as the shell gets it.
    local function runBlock(job)
        assert.are.equal(1, #job.steps, job.name .. " should have one step")
        local body, indent = {}, nil
        local inRun = false
        for _, line in ipairs(splitLines(job.steps[1].text)) do
            if inRun then
                if not line:match("^%s*$") then
                    indent = indent or indentOf(line)
                    if indentOf(line) < indent then break end
                end
                body[#body + 1] = line:sub((indent or 0) + 1)
            elseif line:match("^%s*run: |%s*$") then
                inRun = true
            end
        end
        assert.is_true(#body > 0, job.name .. " has no run: | block")
        return (table.concat(body, "\n"):gsub("%s+$", "")) .. "\n"
    end

    local function nameCheck(job)
        -- Both functions, up to the end of delete_branch (the first unindented }).
        local block = runBlock(job):match("pr_of_branch%(%) {\n.-\ndelete_branch%(%) {\n.-\n}\n")
        assert.is_truthy(block, job.name .. " has no name check")
        return block
    end

    local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end

    local function write(file, content)
        local handle = assert(io.open(file, "w"))
        handle:write(content)
        handle:close()
    end

    local function read(file)
        local handle = io.open(file, "r")
        if not handle then return "" end
        local content = handle:read("*a")
        handle:close()
        return content
    end

    -- A stand-in for curl that answers like GitHub's API from files in its
    -- folder, and logs each call ("METHOD URL") and the config it read. Like
    -- curl, it reads its config from stdin only with -K -, writes the body
    -- unless -o /dev/null (and, with -f, not for a status of 400 or more),
    -- writes the status only with -w '%{http_code}', and with -f exits 22 on
    -- a status of 400 or more. A request without the token gets 401.
    local fakeCurl = [=[#!/bin/bash
dir=$(dirname "$0")
method=GET url= config= out= format= fail=
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method=$2; shift ;;
    -K) [ "$2" = - ] && config=$(cat); shift ;;
    -o) out=$2; shift ;;
    -w) format=$2; shift ;;
    -H) shift ;;
    --*) ;;
    -*f*) fail=1 ;;
    -*) ;;
    *) url=$1 ;;
  esac
  shift
done
echo "$method $url" >> "$dir/calls"
[ -n "$config" ] && printf '%s\n' "$config" >> "$dir/stdin"
body= status=404
if [ "$config" != 'header = "Authorization: Bearer secret-token-123"' ]; then
  status=401 body='{"message":"Requires authentication"}'
else
  case "$method $url" in
    "DELETE "*/git/refs/heads/ui-screenshots/pr-*)
      n=${url##*/pr-}
      status=204
      if [ -f "$dir/delete-$n" ]; then status=$(cat "$dir/delete-$n"); fi
      if [ "$status" = unreachable ]; then
        [ "$format" = '%{http_code}' ] && printf 000
        exit 7
      fi
      [ "$status" = 204 ] || body='{"message":"Reference does not exist"}' ;;
    "GET "*/git/matching-refs/heads/ui-screenshots/)
      if [ -f "$dir/refs.json" ]; then status=200 body=$(cat "$dir/refs.json"); fi ;;
    "GET "*/pulls/*)
      n=${url##*/pulls/}
      if [ -f "$dir/pr-$n" ]; then
        status=200 body=$(printf '{"number":%s,"state":"%s"}' "$n" "$(cat "$dir/pr-$n")")
      fi ;;
  esac
fi
[ "$status" -ge 400 ] && [ -z "$body" ] && body='{"message":"Not Found"}'
if [ "$out" != /dev/null ] && ! { [ -n "$fail" ] && [ "$status" -ge 400 ]; }; then printf '%s' "$body"; fi
[ "$format" = '%{http_code}' ] && printf '%s' "$status"
if [ -n "$fail" ] && [ "$status" -ge 400 ]; then exit 22; fi
exit 0
]=]

    -- Runs a script as GitHub Actions runs a step with shell: bash (bash
    -- --noprofile --norc -eo pipefail), with the fake curl first on PATH.
    -- files are written next to it first.
    -- Returns the exit code, the output, the curl calls, what curl read on
    -- stdin, and the step summary.
    local function runStep(script, env, files)
        local dir = os.tmpname()
        os.remove(dir)
        os.execute('mkdir -p "' .. dir .. '/bin"')
        write(dir .. "/bin/curl", fakeCurl)
        os.execute('chmod +x "' .. dir .. '/bin/curl"')
        for name, content in pairs(files or {}) do write(dir .. "/bin/" .. name, content) end
        local exports = { 'export PATH="' .. dir .. '/bin:$PATH"', "export GITHUB_API_URL=https://api.test",
            'export GITHUB_STEP_SUMMARY="' .. dir .. '/summary"', "export REPO=owner/repo",
            "export TOKEN=secret-token-123" }
        for key, value in pairs(env or {}) do exports[#exports + 1] = "export " .. key .. "=" .. quote(value) end
        write(dir .. "/step.sh", table.concat(exports, "\n") .. "\n" .. script)
        local p = io.popen('bash --noprofile --norc -eo pipefail "' .. dir .. '/step.sh" < /dev/null 2>&1; echo "exit=$?"')
        local output = p:read("*a")
        p:close()
        local code = tonumber(output:match("exit=(%d+)\n$"))
        output = output:gsub("exit=%d+\n$", "")
        local calls, stdin, summary = read(dir .. "/bin/calls"), read(dir .. "/bin/stdin"), read(dir .. "/summary")
        os.execute('rm -rf "' .. dir .. '"')
        return code, output, calls, stdin, summary
    end

    it("runs on closed pull requests and by hand, never on pull_request_target", function()
        assert.is_truthy(header, "no jobs found")
        assert.is_truthy(header:find("\non:\n  pull_request:\n    types: %[closed%]\n  workflow_dispatch:\n"),
            "the triggers aren't exactly pull_request (closed) and workflow_dispatch")
        assert.is_falsy(text:find("pull_request_target"), path .. " uses pull_request_target")
    end)

    it("has no access by default, no secrets, and write access only in its two jobs", function()
        assert.is_truthy(header:find("\npermissions: {}\n"), "the default access isn't none")
        assert.is_falsy(header:find("write"), "the workflow grants write access to every job")
        assert.is_falsy(text:find("secrets%."), path .. " uses secrets")
        local names = {}
        for _, job in ipairs(order) do names[#names + 1] = job.name end
        assert.are.same({ "delete-on-close", "sweep" }, names)

        local function permissions(job)
            local _, block = job.text:match("\n(%s*)permissions:\n(.-)\n%1[%w_-]+:")
            assert.is_truthy(block, job.name .. " has no permissions of its own")
            return block
        end
        local close, sweep = permissions(jobs["delete-on-close"]), permissions(jobs.sweep)
        assert.is_truthy(close:match("^%s*contents: write%s*$"), "delete-on-close has more than contents: write")
        local sweepKeys = {}
        for key, value in sweep:gmatch("([%w_-]+):%s*(%w+)") do sweepKeys[key] = value end
        assert.are.same({ contents = "write", ["pull-requests"] = "read" }, sweepKeys)
        local _, writes = text:gsub("write", "")
        assert.are.equal(2, writes, "write access appears outside the two jobs' contents: write")
    end)

    -- Without shell:, GitHub runs a step as bash -e, without pipefail, so the
    -- tests above would check a shell the step doesn't get (#117).
    it("runs each job's step with shell: bash, the shell the tests use", function()
        for _, job in ipairs(order) do
            assert.are.equal(1, #job.steps, job.name .. " should have one step")
            -- A step's own keys line up after its "- ", as name: does.
            local step = "\n" .. job.steps[1].text:gsub("^(%s*)%-(%s+)", "%1 %2")
            local key = step:match("^\n(%s*)name:")
            assert.is_truthy(key, job.name .. "'s step doesn't start with - name:")
            local shells = {}
            for indent, value in step:gmatch("\n(%s*)shell:%s*([^\n]*)") do
                shells[#shells + 1] = (indent == key and "" or "nested ") .. value
            end
            assert.are.same({ "bash" }, shells, job.name .. "'s step doesn't say shell: bash, once, as its own key")
        end
    end)

    it("checks out and runs nothing: no actions, no checkout, only curl and jq", function()
        assert.is_falsy(text:find("uses:"), path .. " uses an action")
        assert.is_falsy(text:find("checkout"), path .. " checks something out")
        for _, job in ipairs(order) do
            local run = runBlock(job)
            for _, banned in ipairs({ "%f[%w]git%s", "docker", "make ", "%./", "%f[%w]bash%s", "%f[%w]sh%s",
                "source ", "eval", "%f[%w]gh%s", "npm", "pip", "python", "wget", "%${{" }) do
                assert.is_falsy(run:find(banned), job.name .. " runs " .. banned)
            end
        end
    end)

    it("builds the close-time branch name only from the event's pull request number", function()
        local close = jobs["delete-on-close"]
        assert.is_truthy(close, "no delete-on-close job")
        local condition = "github%.event_name == 'pull_request' && "
            .. "github%.event%.pull_request%.head%.repo%.full_name == github%.repository"
        assert.is_truthy(close.text:find("\n    if: %${{ " .. condition .. " }}\n"),
            "delete-on-close runs for forks or outside pull requests")
        for field in close.text:gmatch("github%.event%.pull_request%.([%w_.]+)") do
            assert.is_truthy(field == "number" or field == "head.repo.full_name",
                "delete-on-close reads github.event.pull_request." .. field)
        end
        assert.is_truthy(close.text:find("\n%s+PR: %${{ github%.event%.pull_request%.number }}\n"),
            "PR isn't the event's pull request number")
        assert.is_falsy(jobs.sweep.text:find("github%.event%."), "the sweep reads the event")
        assert.is_truthy(jobs.sweep.text:find("\n    if: %${{ github%.event_name == 'workflow_dispatch' }}\n"),
            "the sweep doesn't run only by hand")
    end)

    it("never fails the pull request's checks", function()
        local close = jobs["delete-on-close"]
        local key = "\n" .. (" "):rep(close.keyIndent) .. "continue%-on%-error:%s*true"
        assert.is_truthy(close.text:find(key), "delete-on-close can fail the pull request")
        assert.is_truthy(runBlock(close):find('\ndelete_branch "%$PR" || true\n$'),
            "delete-on-close's last line can fail")
    end)

    it("uses the same name check in both jobs", function()
        assert.are.equal(nameCheck(jobs["delete-on-close"]), nameCheck(jobs.sweep))
    end)

    describe("close-time job", function()
        local function close(pr, files)
            return runStep(runBlock(jobs["delete-on-close"]), { PR = pr }, files)
        end

        it("deletes the closed pull request's branch, passing the token on stdin only", function()
            local code, output, calls, stdin = close("106")
            assert.are.equal(0, code)
            assert.are.equal("deleted ui-screenshots/pr-106\n", output)
            assert.are.equal("DELETE https://api.test/repos/owner/repo/git/refs/heads/ui-screenshots/pr-106\n", calls)
            assert.are.equal('header = "Authorization: Bearer secret-token-123"\n', stdin)
        end)

        it("treats a branch that's already gone as fine", function()
            for _, status in ipairs({ "404", "422" }) do
                local code, output, calls = close("88", { ["delete-88"] = status })
                assert.are.equal(0, code)
                assert.are.equal("ui-screenshots/pr-88 is already gone\n", output)
                assert.are.equal(1, select(2, calls:gsub("\n", "")))
            end
        end)

        it("only warns when GitHub refuses, so the pull request's checks stay green", function()
            local code, output = close("91", { ["delete-91"] = "403" })
            assert.are.equal(0, code)
            assert.are.equal("::warning::could not delete ui-screenshots/pr-91 (HTTP 403)\n", output)
            code, output = close("91", { ["delete-91"] = "unreachable" })
            assert.are.equal(0, code)
            assert.are.equal("::warning::could not delete ui-screenshots/pr-91 (HTTP 000)\n", output)
        end)

        it("refuses a pull request number that isn't plain digits, and calls nothing", function()
            for _, pr in ipairs({ "", "abc", "12a", "012", "0", "-1", "1 2", "12\n", "12/../main", "../main",
                "12*", "١٢" }) do
                local code, output, calls = close(pr)
                assert.are.equal(0, code, pr)
                assert.are.equal("::warning::refusing to delete a branch for pull request number '" .. pr .. "'\n",
                    output)
                assert.are.equal("", calls, "curl was called for '" .. pr .. "'")
            end
        end)
    end)

    describe("name check", function()
        local function prOf(branch)
            local script = nameCheck(jobs.sweep) .. "pr_of_branch " .. quote(branch) .. "\n"
            local code, output = runStep(script)
            return code == 0 and output:gsub("\n$", "") or nil
        end

        it("reads the number from a screenshots branch", function()
            assert.are.equal("7", prOf("ui-screenshots/pr-7"))
            assert.are.equal("106", prOf("ui-screenshots/pr-106"))
        end)

        it("refuses every branch outside ui-screenshots/pr-<digits>", function()
            for _, branch in ipairs({ "main", "claude/106-x", "ui-screenshots/pr-", "ui-screenshots/pr-07",
                "ui-screenshots/pr-7/x", "ui-screenshots/pr-7a", "ui-screenshots/pr-7\n", "refs/heads/ui-screenshots/pr-7",
                "xui-screenshots/pr-7", "ui-screenshots/pr-7 main", "ui-screenshots/PR-7", "ui-screenshots/pr--7" }) do
                assert.is_nil(prOf(branch), branch)
            end
        end)
    end)

    describe("sweep", function()
        local function refs(names)
            local list = {}
            for _, name in ipairs(names) do list[#list + 1] = '{"ref":"refs/heads/' .. name .. '"}' end
            return "[" .. table.concat(list, ",") .. "]"
        end

        local function sweep(files)
            return runStep(runBlock(jobs.sweep), {}, files)
        end

        it("deletes the branches of closed pull requests only, and keeps the rest", function()
            local code, output, calls, _, summary = sweep({
                ["refs.json"] = refs({ "ui-screenshots/pr-88", "ui-screenshots/pr-91", "ui-screenshots/pr-96",
                    "ui-screenshots/pr-5/x", "ui-screenshots/pr-404", "ui-screenshots/pr-77", "ui-screenshots/pr-08" }),
                ["pr-88"] = "closed", ["pr-91"] = "closed", ["pr-96"] = "open", ["pr-77"] = "closed",
                ["pr-8"] = "closed", ["delete-77"] = "422",
            })
            assert.are.equal(0, code, output)
            local deletes = {}
            for n in calls:gmatch("DELETE https://api%.test/repos/owner/repo/git/refs/heads/ui%-screenshots/pr%-(%d+)\n") do
                deletes[#deletes + 1] = n
            end
            assert.are.same({ "88", "91", "77" }, deletes)
            assert.is_truthy(output:find("keeping ui-screenshots/pr-96: pull request #96 is open", 1, true))
            assert.is_truthy(output:find("keeping ui-screenshots/pr-404: pull request #404 is unknown", 1, true))
            assert.is_truthy(output:find("keeping ui-screenshots/pr-5/x: not a", 1, true))
            assert.is_truthy(output:find("keeping ui-screenshots/pr-08: not a", 1, true))
            assert.is_truthy(output:find("ui-screenshots/pr-77 is already gone", 1, true))
            assert.are.equal("Screenshot branches: deleted 3, kept 4, failed 0.\n", summary)
            assert.is_falsy(calls:find("pulls/8\n", 1, true), "looked up a pull request from a refused name")
        end)

        it("finishes cleanly with nothing to delete", function()
            local code, output, calls = sweep({ ["refs.json"] = "[]" })
            assert.are.equal(0, code)
            assert.are.equal("deleted 0, kept 0, failed 0\n", output)
            assert.are.equal("GET https://api.test/repos/owner/repo/git/matching-refs/heads/ui-screenshots/\n", calls)
        end)

        it("fails, deleting nothing, when it can't list the branches", function()
            for _, listing in ipairs({ false, '{"message":"Not Found"}', "not json" }) do
                local code, output, calls = sweep({ ["refs.json"] = listing or nil })
                assert.are_not.equal(0, code)
                assert.is_truthy(output:find("::error::could not list the branches", 1, true))
                assert.is_falsy(calls:find("DELETE"), "deleted after a failed listing")
            end
        end)

        it("carries on past a branch it can't delete, then fails so the owner sees it", function()
            local code, output, calls, _, summary = sweep({
                ["refs.json"] = refs({ "ui-screenshots/pr-1", "ui-screenshots/pr-2" }),
                ["pr-1"] = "closed", ["pr-2"] = "closed", ["delete-1"] = "500",
            })
            assert.are_not.equal(0, code)
            assert.is_truthy(output:find("::warning::could not delete ui-screenshots/pr-1 (HTTP 500)", 1, true))
            assert.is_truthy(calls:find("heads/ui-screenshots/pr-2\n", 1, true))
            assert.are.equal("Screenshot branches: deleted 1, kept 0, failed 1.\n", summary)
        end)
    end)
end)

describe("Release workflow", function()
    local path = ".github/workflows/release.yml"
    local order

    setup(function() order = select(2, parseWorkflow(path)) end)

    it("defaults to read-only access", function()
        assert.is_truthy(wow.readFile(path):find("\npermissions:\n  contents: read\n", 1, true))
    end)

    it("verifies the tag and runs the tests in a job with no secrets or approval", function()
        local verify = jobWith(order, "make test")
        assert.is_truthy(verify, "release never runs the tests")
        for _, gate in ipairs({ "merge%-base %-%-is%-ancestor", "FriendlyForever%.toc", "make lint" }) do
            assert.is_truthy(verify.text:find(gate), "the test job doesn't check " .. gate)
        end
        assert.is_falsy(verify.text:find("secrets%."), "the test job can read secrets")
        assert.is_falsy(verify.text:find("environment:"), "approval is asked before the checks run")
        assert.is_falsy(verify.text:find(":%s*write"), "the test job has write access")
    end)

    it("uploads only from an approved job that needs the verify job", function()
        local release = jobWith(order, "BigWigsMods/packager@")
        local verify = jobWith(order, "make test")
        assert.is_truthy(release and release ~= verify, "upload runs in the same job as the checks")
        assert.is_truthy(release.keys.needs and release.text:find("needs:%s*%[?%s*" .. verify.name:gsub("%-", "%%-")),
            release.name .. " doesn't need " .. verify.name)
        assert.is_truthy(release.text:find("environment:%s*release"), "upload skips the approval environment")
        assert.is_falsy(release.text:find("make setup", 1, true), "the job holding the key builds third-party tools")
    end)

    it("checks the CurseForge config and writes the notes before uploading", function()
        local release = jobWith(order, "BigWigsMods/packager@")
        local upload = indexOf(release.steps, "BigWigsMods/packager@")
        local config = indexOf(release.steps, "X%-Curse%-Project%-ID")
        assert.is_truthy(config and config < upload, "upload can run without a project ID")
        assert.is_truthy(release.steps[config].text:find("CF_API_KEY", 1, true), "upload can run without a key")
        local notes = indexOf(release.steps, "make release%-notes")
        assert.is_truthy(notes and notes < upload, "release notes aren't written before uploading")
    end)

    it("passes secrets only to the steps that need them", function()
        local release = jobWith(order, "BigWigsMods/packager@")
        for _, job in ipairs(order) do
            assert.is_falsy(job.keys.env, job.name .. " sets env for the whole job")
        end
        for _, step in ipairs(release.steps) do
            if step.text:find("secrets%.") then
                assert.is_truthy(step.text:find("BigWigsMods/packager@") or step.text:find("X%-Curse%-Project%-ID"),
                    "a step that neither checks config nor uploads can read secrets")
            end
        end
    end)
end)

describe("CurseForge packager config", function()
    local function pkgmeta()
        local ignored, changelog, section = {}, nil, nil
        for _, line in ipairs(lines(".pkgmeta")) do
            if line:match("^%S") then
                section = line:match("^([%w_-]+):")
            elseif section == "ignore" then
                local entry = line:match("^%s+%-%s+[\"']?([^%s#\"']+)")
                if entry then ignored[entry] = true end
            elseif section == "manual-changelog" then
                changelog = line:match("^%s+filename:%s*[\"']?([^%s#\"']+)") or changelog
            end
        end
        return ignored, changelog
    end

    -- The packager zips the repo minus .pkgmeta's ignore list (and dotfiles);
    -- scripts/package.sh builds the zip from the TOC. Every top-level entry
    -- must be shipped by the TOC or ignored, so the two never differ.
    it("ignores every top-level file the TOC doesn't ship", function()
        local ignored = pkgmeta()
        assert.is_truthy(next(ignored), ".pkgmeta has no ignore list")
        -- The TOC itself and scripts/package.sh's extras (Bindings.xml is
        -- loaded by the game without being listed in the TOC, and Media/
        -- holds the textures the code and the TOC name by path).
        local shipped = { ["FriendlyForever.toc"] = true, ["README.md"] = true,
            ["CHANGELOG.md"] = true, ["LICENSE"] = true, ["Bindings.xml"] = true, ["Media"] = true }
        local _, files = wow.parseToc()
        for _, file in ipairs(files) do shipped[file:match("^[^/]+")] = true end

        local count = 0
        local list = io.popen('cd "' .. wow.ROOT .. '" && (git ls-files 2>/dev/null || ls -A)')
        for path in list:read("*a"):gmatch("[^\n]+") do
            count = count + 1
            local top = path:match("^[^/]+")
            if top:sub(1, 1) ~= "." then
                assert.is_truthy(shipped[top] or ignored[top], top .. " would ship to CurseForge; add it to .pkgmeta ignore")
            end
        end
        list:close()
        assert.is_true(count > 0, "no repository files listed")
    end)

    it("uses the generated release notes as the changelog, without shipping them", function()
        local ignored, changelog = pkgmeta()
        assert.are.equal("RELEASE_NOTES.md", changelog)
        assert.is_true(ignored[changelog])
    end)
end)

-- #103: one pinned toolchain setup, documented in CONTRIBUTING.md.
describe("Toolchain setup", function()
    local function pin(name)
        return wow.readFile("scripts/dev-setup.sh"):match("\n" .. name .. '="([^"]+)"')
    end

    -- The version table in CONTRIBUTING.md's Local setup section.
    local function documented()
        local docs = wow.readFile("CONTRIBUTING.md")
        local section = docs:match("\n## Local setup\n(.-)\n## ")
        local versions = {}
        for tool, version in (section or ""):gmatch("\n| ([%w ]-) | ([%w.%-]+) |") do
            versions[tool] = version
        end
        return versions, section
    end

    it("pins the versions CONTRIBUTING.md documents", function()
        local versions, section = documented()
        assert.is_truthy(section, "CONTRIBUTING.md has no Local setup section")
        local pins = { hererocks = "HEREROCKS_VERSION", Lua = "LUA_VERSION", LuaRocks = "LUAROCKS_VERSION",
            busted = "BUSTED_VERSION", luacheck = "LUACHECK_VERSION" }
        for tool, variable in pairs(pins) do
            assert.is_truthy(pin(variable), "dev-setup.sh doesn't pin " .. variable)
            assert.are.equal(pin(variable), versions[tool], tool .. " in CONTRIBUTING.md")
        end
    end)

    it("is what make setup runs", function()
        local recipe = wow.readFile("Makefile"):match("\nsetup:\n(.-)\n\n")
        assert.are.equal('\t./scripts/dev-setup.sh "$(TOOLS)"', recipe)
    end)

    it("documents every download host and the claude.ai setup script", function()
        local _, section = documented()
        for host in wow.readFile("scripts/dev-setup.lock"):gmatch("https://([^/%s]+)/") do
            assert.is_truthy(section:find("`" .. host .. "`", 1, true), host .. " isn't listed in CONTRIBUTING.md")
        end
        assert.is_truthy(section:find("make %-C /home/user/FriendlyForever setup"), "no one-line setup script")
    end)

    it("allows every download host in the claude.ai environment settings", function()
        local _, section = documented()
        local claude = section:match("\n### claude%.ai environment\n(.*)") or ""
        local allowed = {}
        for host in (claude:match("```\n(.-)\n%s*```") or ""):gmatch("[^%s]+") do allowed[host] = true end
        local default = claude:match("default list already has ([^\n]*)") or ""
        for host in wow.readFile("scripts/dev-setup.lock"):gmatch("https://([^/%s]+)/") do
            assert.is_truthy(allowed[host] or default:find("`" .. host .. "`", 1, true),
                host .. " is neither allowed nor in the default list in CONTRIBUTING.md's claude.ai environment settings")
        end
    end)

    it("keeps every development-only path out of the CurseForge package", function()
        local ignored = {}
        local inIgnore = false
        for _, line in ipairs(lines(".pkgmeta")) do
            if line:match("^%S") then inIgnore = line:match("^ignore:") ~= nil
            elseif inIgnore then
                local entry = line:match("^%s+%-%s+[\"']?([^%s#\"']+)")
                if entry then ignored[entry] = true end
            end
        end
        for _, path in ipairs({ "scripts", "spec", "uitests", ".github", "Makefile", "CONTRIBUTING.md", "CLAUDE.md",
            ".busted", ".luacheckrc", ".gitignore" }) do
            assert.is_true(ignored[path], path .. " isn't in .pkgmeta's ignore list")
        end
        -- The setup script and its checksums live in an ignored folder.
        assert.is_true(ignored[("scripts/dev-setup.sh"):match("^[^/]+")])
        assert.is_true(ignored[("scripts/dev-setup.lock"):match("^[^/]+")])
    end)
end)

-- Claude Code keeps side sessions' checkouts in .claude/worktrees (#77).
-- CI never has one, so only these tests notice if lint or git starts
-- reading them again (make check would fail locally while one is open).
describe("Claude Code worktrees", function()
    it("are left out of the lint", function()
        -- Run the config as luacheck does: its per-file sections (files[...])
        -- are made as they're named.
        local config = { files = setmetatable({}, { __index = function(t, k) t[k] = {} return t[k] end }) }
        local chunk = assert(loadfile(wow.ROOT .. ".luacheckrc"))
        setfenv(chunk, config)()
        local excluded = {}
        for _, pattern in ipairs(config.exclude_files or {}) do excluded[pattern] = true end
        assert.is_true(excluded[".claude/**"], ".luacheckrc exclude_files")
    end)

    it("are git-ignored", function()
        local found = false
        for _, line in ipairs(lines(".gitignore")) do
            if line == ".claude/worktrees/" then found = true end
        end
        assert.is_true(found, ".gitignore")
    end)
end)

describe("Release version check", function()
    -- Runs the release job's own lines: read the TOC version, then compare it
    -- with the tag and exit 1 on a mismatch, so a wrong tag can't start an upload.
    local text = withoutComments(wow.readFile(".github/workflows/release.yml"))
    local readToc = text:match('(toc="%$%(sed [^\n]*%)")')
    -- The comparison and the line that stops the job when it fails. The match
    -- must run to the end of the line: anything after `exit 1; }`, such as
    -- `|| true`, would let a mismatched tag through (#95). The start is
    -- anchored too: only spaces or tabs may come before `[[`, since `true || `
    -- or `! ` there would also let one through (#127).
    local function compareLines(workflow)
        return ("\n" .. workflow .. "\n"):match('\n[ \t]*(%[%[ "v%$toc" == "%$GITHUB_REF_NAME" %]%] \\\n[^\n]*exit 1; })[ \t]*\n')
    end
    local compare = compareLines(text)

    local function accepts(toc, tag)
        assert(readToc and compare, "release.yml no longer reads the TOC version and compares it with the tag")
        local dir = os.tmpname()
        os.remove(dir)
        os.execute('mkdir -p "' .. dir .. '"')
        local file = assert(io.open(dir .. "/FriendlyForever.toc", "w"))
        file:write(toc)
        file:close()
        local script = assert(io.open(dir .. "/check.sh", "w"))
        script:write("GITHUB_REF_NAME='" .. tag .. "'\n" .. readToc .. "\n" .. compare .. "\n")
        script:close()
        -- The job's ::error:: line goes to a file, not the terminal: on CI,
        -- GitHub Actions would read it as a real error annotation (#89).
        local ok = os.execute('cd "' .. dir .. '" && bash check.sh > out.txt 2>&1')
        local out = assert(io.open(dir .. "/out.txt", "r"))
        local output = out:read("*a")
        out:close()
        os.execute('rm -rf "' .. dir .. '"')
        return ok == true or ok == 0, output
    end

    -- A rejected tag stops the job and says why, in the error line that
    -- GitHub Actions shows on the run.
    local function rejects(toc, tag, version)
        local ok, output = accepts(toc, tag)
        assert.is_false(ok)
        assert.are.equal("::error::Tag " .. tag .. " does not match TOC version " .. version .. "\n", output)
    end

    it("keeps the tag check from being skipped or allowed to fail", function()
        local _, order = parseWorkflow(".github/workflows/release.yml")
        local verify = jobWith(order, "GITHUB_REF_NAME\" %]%]")
        assert.is_truthy(verify, "no job checks the tag against the TOC")
        assert.is_falsy(verify.keys["if"] or verify.keys["continue-on-error"], verify.name .. " can be skipped or fail quietly")
        local step = verify.steps[indexOf(verify.steps, "GITHUB_REF_NAME\" %]%]")]
        assert.is_falsy(step.text:find("\n%s+if:") or step.text:find("^%s*%- if:"), "the tag check step can be skipped")
        assert.is_falsy(step.text:find("continue%-on%-error"), "the tag check step can fail quietly")

        -- The upload job must wait for verify to pass: an `if` such as always()
        -- would let it run after a failed tag check.
        local release = jobWith(order, "BigWigsMods/packager@")
        assert.is_truthy(release, "no job uploads")
        assert.is_falsy(release.keys["if"], release.name .. " has an if: it can run after a failed " .. verify.name)
        assert.is_falsy(release.keys["continue-on-error"], release.name .. " is allowed to fail quietly")
    end)

    it("finds the release job's two lines", function()
        assert.is_truthy(readToc, "release.yml no longer reads the TOC version")
        assert.is_truthy(compare, "release.yml no longer compares the tag with the TOC")
    end)

    it("doesn't find the compare line when anything follows exit 1 on it, such as || true", function()
        -- Changes only the tag compare line, the one that ends with the TOC version.
        local line = 'TOC version $toc"; exit 1; }'
        local function withTail(tail)
            local at = text:find(line, 1, true)
            assert.is_truthy(at, "release.yml has no tag compare line to change")
            local stop = at + #line
            return text:sub(1, stop - 1) .. tail .. text:sub(stop)
        end
        for _, tail in ipairs({ " || true", "; true", " ||true", " || :" }) do
            assert.is_falsy(compareLines(withTail(tail)), "the compare line still matches with" .. tail .. " after it")
        end
        -- Trailing spaces change nothing, so they still match.
        assert.is_truthy(compareLines(withTail("  ")))
    end)

    it("doesn't find the compare line when anything comes before [[ on it, such as true ||", function()
        local start = '[[ "v$toc" == "$GITHUB_REF_NAME" ]]'
        local function withHead(head)
            local at = text:find(start, 1, true)
            assert.is_truthy(at, "release.yml has no tag compare line to change")
            return text:sub(1, at - 1) .. head .. text:sub(at)
        end
        for _, head in ipairs({ "true || ", "! ", "true||", "x=1; ", ": && " }) do
            assert.is_falsy(compareLines(withHead(head)), "the compare line still matches with " .. head .. " before it")
        end
        -- Spaces and tabs change nothing, so they still match.
        assert.is_truthy(compareLines(withHead("\t ")))
    end)

    it("accepts the tag for the TOC's own version, and prints nothing", function()
        local toc = wow.readFile("FriendlyForever.toc")
        local ok, output = accepts(toc, "v" .. wow.parseToc().Version)
        assert.is_true(ok)
        assert.are.equal("", output)
        ok, output = accepts("## Version: 0.8.0\n", "v0.8.0")
        assert.is_true(ok)
        assert.are.equal("", output)
    end)

    it("rejects a tag that is not the TOC's version, or a TOC with no version, naming the tag and the version", function()
        rejects("## Version: 0.8.0\n", "v1.6.0", "0.8.0")
        rejects("## Version: 0.8.0\n", "v0.8.0-beta", "0.8.0")
        rejects("## Version: 0.8.0\n", "0.8.0", "0.8.0")
        rejects("## Title: Friendly Forever\n", "v0.8.0", "")
    end)

    it("still accepts the right tag when the TOC has Windows line endings", function()
        local ok, output = accepts("## Version: 0.8.0\r\n## Title: x\r\n", "v0.8.0")
        assert.is_true(ok)
        assert.are.equal("", output)
    end)
end)

describe("CurseForge project ID", function()
    -- The release job refuses to upload without a numeric ID in the TOC. The
    -- test runs that job's own grep, so the check and the file can't drift.
    local pattern = wow.readFile(".github/workflows/release.yml"):match("grep %-Eq '([^']+)' FriendlyForever%.toc")

    local function accepted(toc)
        local path = os.tmpname()
        local f = assert(io.open(path, "w"))
        f:write(toc)
        f:close()
        local ok = os.execute("grep -Eq '" .. pattern .. "' " .. path)
        os.remove(path)
        return ok == true or ok == 0
    end

    it("is the project's ID, in the form the release check accepts", function()
        assert.is_truthy(pattern, "release.yml has no project ID check")
        assert.are.equal("1769620", wow.parseToc()["X-Curse-Project-ID"])
        assert.is_true(accepted(wow.readFile("FriendlyForever.toc")))
    end)

    it("is rejected by the release check when missing or not a number", function()
        assert.is_false(accepted("## Version: 0.8.0\n"))
        assert.is_false(accepted("## X-Curse-Project-ID: abc\n"))
        assert.is_false(accepted("## X-Curse-Project-ID:\n"))
    end)

    it("still passes the check when the TOC has Windows line endings", function()
        local crlf = wow.readFile("FriendlyForever.toc"):gsub("\r?\n", "\r\n")
        assert.is_truthy(crlf:find("\r\n", 1, true), "the test input has no Windows line endings")
        assert.is_true(accepted(crlf))
    end)
end)

describe("Release scripts", function()
    local function run(cmd)
        local p = io.popen('cd "' .. wow.ROOT .. '" && ' .. cmd .. ' 2>&1; echo "exit=$?"')
        local out = p:read("*a")
        p:close()
        return out, tonumber(out:match("exit=(%d+)%s*$"))
    end

    it("release notes hold only the TOC version's changelog section", function()
        local _, code = run("./scripts/release-notes.sh")
        assert.are.equal(0, code)
        local notes = wow.readFile("RELEASE_NOTES.md")
        local headings = {}
        for heading in ("\n" .. notes):gmatch("\n## ([^\n]+)") do headings[#headings + 1] = heading end
        assert.are.same({ wow.parseToc().Version }, headings)
        -- The changelog's issue tags (#27) mean nothing to players, so the
        -- notes leave them out; otherwise they're the section word for word.
        local Changelog = require("spec.support.changelog")
        local kept = {}
        for _, line in ipairs(Changelog.Lines(wow.readFile("CHANGELOG.md"))) do kept[#kept + 1] = Changelog.WithoutTag(line) end
        local withoutTags = table.concat(kept, "\n")
        assert.is_truthy(withoutTags:find(notes, 1, true), "notes aren't a slice of the changelog")
    end)

    it("release notes leave out the issue tags players can't use", function()
        local dir = os.tmpname()
        os.remove(dir)
        os.execute('mkdir -p "' .. dir .. '"')
        local file = io.open(dir .. "/CHANGELOG.md", "w")
        file:write("# Changelog\n\n## 1.7.0\n\n- One. (#27)\n- Two. (#27, #52)  \n- Kept (as written).\n- Not a tag (#)\n\n## 1.6.0\n")
        file:close()
        local out, code = run('./scripts/release-notes.sh "' .. dir .. '/CHANGELOG.md" "' .. dir .. '/NOTES.md"')
        local notesFile = io.open(dir .. "/NOTES.md")
        local notes = notesFile and notesFile:read("*a")
        if notesFile then notesFile:close() end
        os.execute('rm -rf "' .. dir .. '"')
        assert.are.equal(0, code, out)
        assert.are.equal("## 1.7.0\n\n- One.\n- Two.\n- Kept (as written).\n- Not a tag (#)\n\n", notes)
    end)

    it("release notes are the same for a changelog with Windows line endings", function()
        local dir = os.tmpname()
        os.remove(dir)
        os.execute('mkdir -p "' .. dir .. '"')
        local text = wow.readFile("CHANGELOG.md")
        local crlf = text:gsub("\r?\n", "\r\n")
        assert.is_truthy(crlf:find("\r\n", 1, true), "the test input has no Windows line endings")
        for name, body in pairs({ lf = text, crlf = crlf }) do
            local file = io.open(dir .. "/" .. name .. ".md", "wb")
            file:write(body)
            file:close()
        end
        local _, a = run('./scripts/release-notes.sh "' .. dir .. '/lf.md" "' .. dir .. '/lf-out.md"')
        local _, b = run('./scripts/release-notes.sh "' .. dir .. '/crlf.md" "' .. dir .. '/crlf-out.md"')
        local lf, crlfNotes = io.open(dir .. "/lf-out.md"), io.open(dir .. "/crlf-out.md")
        local same = lf and crlfNotes and lf:read("*a") == crlfNotes:read("*a")
        if lf then lf:close() end
        if crlfNotes then crlfNotes:close() end
        os.execute('rm -rf "' .. dir .. '"')
        assert.are.equal(0, a)
        assert.are.equal(0, b)
        assert.is_true(same, "Windows line endings changed the release notes")
    end)

    -- Notes for the next release sit under "### Unreleased" until the
    -- release PR renames it; they must never reach a CurseForge upload.
    it("release notes leave out the Unreleased section", function()
        local _, code = run("./scripts/release-notes.sh")
        assert.are.equal(0, code)
        assert.is_nil(wow.readFile("RELEASE_NOTES.md"):find("Unreleased", 1, true))
    end)

    it("package comparison passes on matching zips and fails on different ones", function()
        local zip = run("./scripts/package.sh"):match("([^\n]*%.zip)")
        assert.is_truthy(zip, "package script did not report a zip")
        local _, same = run('./scripts/compare-packages.sh "' .. zip .. '" "' .. zip .. '"')
        assert.are.equal(0, same)

        local base = os.tmpname()
        os.remove(base)
        local short = base .. ".zip"
        run('cp "' .. zip .. '" "' .. short .. '" && zip -qd "' .. short .. '" FriendlyForever/Core.lua')
        local out, differ = run('./scripts/compare-packages.sh "' .. zip .. '" "' .. short .. '"')
        os.remove(short)
        assert.are_not.equal(0, differ)
        assert.is_truthy(out:find("FriendlyForever/Core.lua", 1, true))
    end)
end)

-- The Release workflow's packager creates the GitHub release itself (#82), so
-- the docs must never tell the maintainer to make one: GitHub refuses a second
-- release for a tag, and one made before the upload is overwritten.
describe("Release docs", function()
    -- Wording that has the reader make the release: "you" or "the maintainer"
    -- as the one making it, the GitHub CLI's command, or GitHub's own button
    -- and page for making one. Imperative verbs are found in manualReleaseSteps.
    local MANUAL = { "generate release notes", "releases/new", "release create" }
    local VERBS = { { "create", "creates" }, { "make", "makes" }, { "publish", "publishes" }, { "draft", "drafts" } }
    for _, forms in ipairs(VERBS) do
        MANUAL[#MANUAL + 1] = "you " .. forms[1]
        MANUAL[#MANUAL + 1] = "maintainer " .. forms[2]
    end

    -- Each manual-release instruction in text, as the words that matched.
    -- Case, markdown emphasis and line breaks (LF or CRLF) don't hide one.
    -- An imperative verb counts when "release" follows within three words
    -- ("create a new GitHub release"), but not the workflow's "creates" or
    -- the command `make release-notes`.
    local function manualReleaseSteps(text)
        local flat = text:lower():gsub("[%*_`]", ""):gsub("%s+", " ")
        local found = {}
        for _, pattern in ipairs(MANUAL) do
            local match = flat:match(pattern)
            if match then found[#found + 1] = match end
        end
        -- Looks from every use of the verb, so a far "release" after one use
        -- can't hide a near one after the next ("make sure ... and make a release").
        for _, forms in ipairs(VERBS) do
            local at, stop = flat:find(forms[1] .. " ", 1, true)
            while at do
                local words, release = flat:match("^([%w ]-)(releases?)%f[^%w%-]", stop + 1)
                if words and select(2, words:gsub("%S+", "")) <= 3 then
                    found[#found + 1] = forms[1] .. " " .. words .. release
                end
                at, stop = flat:find(forms[1] .. " ", at + 1, true)
            end
        end
        return found
    end

    describe("finder", function()
        it("finds the old instructions to create the release by hand", function()
            local old = "- **Releases:** after tagging, the maintainer creates a GitHub release for the tag with "
                .. "**Generate release notes**, which lists the pull requests and the issues they closed.\n"
                .. "2. After it merges, tag the merge commit and push the tag. Then create a GitHub release "
                .. "for the tag with **Generate release notes**.\n"
            assert.are.same({ "generate release notes", "maintainer creates", "create a github release" },
                manualReleaseSteps(old))
        end)

        it("finds a manual step however it is worded", function()
            for _, text in ipairs({
                "Then create the GitHub release.",
                "Create a release for the tag.",
                "Create an annotated GitHub release.",
                "Create a new GitHub release.",
                "Then create GitHub release v0.8.0 for the tag.",
                "Create GitHub releases for both tags.",
                "Make sure the tag is on main and make a GitHub release.",
                "Create the tag, then create the release.",
                "Then run `gh release create v0.8.0 --generate-notes`.",
                "Then make a GitHub release for the tag.",
                "Then publish the GitHub release for the tag.",
                "Then draft the GitHub release.",
                "After the run, you make its page on GitHub.",
                "Afterwards the maintainer publishes it.",
                "Once it's tagged, you create its page on GitHub.",
                "Open the release, then click Draft a new release.",
                "Go to https://github.com/CKozanecki/FriendlyForever/releases/new and fill it in.",
                "Edit it and press *Generate* `release notes`.",
            }) do
                assert.are_not.same({}, manualReleaseSteps(text), text)
            end
        end)

        it("finds one split across lines, including Windows line endings", function()
            assert.are_not.same({}, manualReleaseSteps("Then create a\nGitHub release."))
            assert.are_not.same({}, manualReleaseSteps("Then create a\r\nGitHub release.\r\n"))
        end)

        it("accepts docs that say the workflow creates the release", function()
            assert.are.same({}, manualReleaseSteps("The Release workflow creates the GitHub release for each tag. "
                .. "The GitHub release isn't made by hand: the workflow makes it in step 3. "
                .. "Run `make release-notes` to preview the notes. "
                .. "Make sure the zip holds the README and the release notes."))
        end)
    end)

    describe("the real docs", function()
        for _, path in ipairs({ "CONTRIBUTING.md", "README.md" }) do
            it(path .. " never tells the maintainer to create a GitHub release for the tag", function()
                assert.are.same({}, manualReleaseSteps(wow.readFile(path)))
            end)
        end

        it("CONTRIBUTING.md says the workflow creates the release, with the changelog as its notes, "
            .. "and the maintainer does nothing after the run", function()
            local flat = wow.readFile("CONTRIBUTING.md"):gsub("%s+", " ")
            assert.is_truthy(flat:find("the Release workflow creates the GitHub release for each tag", 1, true))
            assert.is_truthy(flat:find("Its notes are that version's changelog section", 1, true))
            assert.is_truthy(flat:find("The GitHub release isn't made by hand: the workflow makes it", 1, true))
            assert.is_truthy(flat:find("creates the GitHub release for the tag, with the same notes", 1, true))
            assert.is_truthy(flat:find("Once the job is green, there's nothing left to do.", 1, true))
        end)
    end)
end)

-- Claude sessions' reviewer agents, knowledge files and skills (#104). They
-- never ship, and the agents must ask for the output CLAUDE.md requires.
describe("Claude sessions' agents, knowledge and skills", function()
    -- The YAML front matter's simple "key: value" lines (none without one).
    local function frontMatter(text)
        local body = text:gsub("\r\n", "\n"):match("^%-%-%-\n(.-)\n%-%-%-") or ""
        local fields = {}
        for _, line in ipairs(splitLines(body)) do
            local k, v = line:match("^([%w_-]+):%s*(.-)%s*$")
            if k then fields[k] = v end
        end
        return fields
    end

    -- The text under a "## title" heading, up to the next "## " heading
    -- ("" without one).
    local function section(text, title)
        local out, inside = {}, false
        for _, line in ipairs(splitLines(text)) do
            if line:match("^## ") then inside = line == "## " .. title
            elseif inside then out[#out + 1] = line end
        end
        return table.concat(out, "\n")
    end

    -- What an agent file is missing of its required output, as a list.
    local function agentProblems(text, name)
        local problems = {}
        local fields = frontMatter(text)
        if fields.name ~= name then problems[#problems + 1] = "name isn't " .. name end
        if not fields.description or fields.description == "" then problems[#problems + 1] = "no description" end
        local output = section(text, "Output")
        for _, words in ipairs({ "`file:line`", "concrete failure scenario", "as the last line" }) do
            if not output:find(words, 1, true) then problems[#problems + 1] = "Output doesn't say " .. words end
        end
        local verdicts = {}
        for verdict in output:gmatch("\n%s*%- `([A-Z ]+)`") do verdicts[#verdicts + 1] = verdict end
        if table.concat(verdicts, ", ") ~= "APPROVED, CHANGES REQUESTED" then
            problems[#problems + 1] = "verdicts aren't APPROVED and CHANGES REQUESTED"
        end
        local count = 0
        for _, line in ipairs(splitLines(section(text, "Lessons"))) do
            if line:match("^%s*%- ") then
                count = count + 1
                if not line:find("#%d+") then problems[#problems + 1] = "a lesson cites nothing: " .. line end
            end
        end
        if count == 0 then problems[#problems + 1] = "no Lessons" end
        return problems
    end

    -- Facts without a source, and launch checks that don't link #50, in a
    -- knowledge file. A bullet's source is an issue or a link other than its
    -- #50 launch-check link (#118); a table row's is its last cell (an issue,
    -- or the file it comes from), less any #50 link (#122). A link with no address goes nowhere, so it
    -- counts as no link, and a link shown as #N must go to issue or pull
    -- request N.
    local function withoutLaunchCheckLinks(line)
        return (line:gsub("https?://[^%s)]*/issues/50%f[%D][^%s)]*", ""):gsub("#50%f[%D]", ""))
    end

    local function isSeparatorRow(row)
        for cell in (row .. "|"):gmatch("([^|]*)|") do
            if not cell:match("^%s*:?%-+:?%s*$") then return false end
        end
        return true
    end

    local function factProblems(text)
        local problems = {}
        for _, line in ipairs(splitLines(text)) do
            local row = line:match("^|(.*)|%s*$")
            local fact = line:match("^%s*%- ") or row
            if line:find("%]%(%s*%)") then problems[#problems + 1] = "empty link: " .. line end
            for shown, address in line:gmatch("%[#(%d+)%]%(([^)]*)%)") do
                local issue = address:match("/issues/(%d+)") or address:match("/pull/(%d+)")
                if issue and issue ~= shown then
                    problems[#problems + 1] = "#" .. shown .. " links to #" .. issue .. ": " .. line
                end
            end
            local sources = withoutLaunchCheckLinks(line)
            if line:match("^%s*%- ") and not (sources:find("#%d+") or sources:find("https?://")) then
                problems[#problems + 1] = "no source: " .. line
            end
            -- A table row's last cell, less its #50 links and what's left of
            -- them, must still name something (#122). The row under the
            -- header, where every cell is dashes with optional colons, needs
            -- none; a blank row isn't one.
            local cell = row and withoutLaunchCheckLinks(row:match("([^|]*)$")):gsub("%[[^%]]*%]%(%)", "")
            if cell and not cell:find("%w") and not isSeparatorRow(row) then
                problems[#problems + 1] = "no source: " .. line
            end
            if fact and line:lower():find("launch check", 1, true) and not (line:find("#50%f[%D]")
                or line:find("/issues/50#", 1, true)) then
                problems[#problems + 1] = "launch check without #50: " .. line
            end
        end
        return problems
    end

    -- What a skill's SKILL.md is missing, as a list.
    local function skillProblems(text, name)
        local fields = frontMatter(text)
        local problems = {}
        if fields.name ~= name then problems[#problems + 1] = "name isn't " .. name end
        if not fields.description or fields.description == "" then problems[#problems + 1] = "no description" end
        return problems
    end

    local AGENTS = { "lua-architect", "lua-tester" }
    local SKILLS = { "after-merge", "merge-order", "coordinator" }
    local DOCS = { "docs/forever-facts.md", "docs/simulated-client.md", "docs/ui-simulator.md" }

    it(".pkgmeta keeps .claude/ and docs/ out of the release", function()
        local ignored = {}
        for _, line in ipairs(lines(".pkgmeta")) do
            local entry = line:match("^%s+%-%s+[\"']?([^%s#\"']+)")
            if entry then ignored[entry] = true end
        end
        assert.is_true(ignored[".claude"], ".claude")
        assert.is_true(ignored["docs"], "docs")
    end)

    describe("the checks themselves", function()
        local good = table.concat({
            "---", "name: lua-x", "description: A review.", "---", "", "## Output", "",
            "1. **Findings,** each with `file:line` and a **concrete failure scenario**.",
            "2. **The verdict, as the last line, exactly one of:**",
            "   - `APPROVED`: no findings;", "   - `CHANGES REQUESTED`: at least one finding.", "",
            "## Lessons", "", "- Check this (#72).", "",
        }, "\n")

        it("pass a complete agent file", function()
            assert.are.same({}, agentProblems(good, "lua-x"))
        end)

        it("catch an agent file missing any part of its required output", function()
            for _, cut in ipairs({
                { "name: lua%-x", "name: other" },
                { "description: A review%.", "description:" },
                { "`file:line`", "the file" },
                { "concrete failure scenario", "scenario" },
                { "as the last line", "somewhere" },
                { "   %- `CHANGES REQUESTED`[^\n]*\n", "" },
                { "`APPROVED`", "`LGTM`" },
                { "## Output", "## Result" },
                { " %(#72%)", "" },
                { "%- Check this %(#72%)%.", "" },
                { "%- Check this %(#72%)%.", "- Check this (#72).\n  - And this." },
                { "^%-%-%-\n", "" },
                { "^", "# Title\n\n" },
            }) do
                local broken = good:gsub(cut[1], cut[2])
                assert.are_not.equal(good, broken, cut[1])
                assert.are_not.same({}, agentProblems(broken, "lua-x"), cut[1])
            end
        end)

        it("read an agent file with Windows line endings", function()
            local crlf = good:gsub("\n", "\r\n")
            assert.is_truthy(crlf:find("\r\n", 1, true))
            assert.are.same({}, agentProblems(crlf, "lua-x"))
        end)

        it("look for the required output only in the Output section", function()
            for _, cut in ipairs({
                { "as the last line", "somewhere", "It ends as the last line." },
                { "   %- `CHANGES REQUESTED`[^\n]*\n", "", "   - `CHANGES REQUESTED`: not (#1)." },
            }) do
                local moved = good:gsub(cut[1], cut[2]) .. "\n## Other\n\n" .. cut[3] .. "\n"
                assert.is_falsy(section(moved, "Output"):find(cut[3], 1, true), cut[1])
                assert.are_not.same({}, agentProblems(moved, "lua-x"), cut[1])
            end
        end)

        it("pass a complete skill, and catch one with the wrong name, no description or no front matter", function()
            local skill = "---\nname: merge-x\ndescription: Does it.\n---\n\n# Merge x\n"
            assert.are.same({}, skillProblems(skill, "merge-x"))
            for _, cut in ipairs({ { "name: merge%-x", "name: other" }, { "description: Does it%.", "description:" },
                { "^%-%-%-\n", "" }, { "^", "# Title\n\n" } }) do
                local broken = skill:gsub(cut[1], cut[2])
                assert.are_not.equal(skill, broken, cut[1])
                assert.are_not.same({}, skillProblems(broken, "merge-x"), cut[1])
            end
        end)

        it("catch a fact with no source, and a launch check that doesn't link #50", function()
            assert.are.same({}, factProblems("# T\n\nProse needs none.\n- A fact (#34).\n"
                .. "- See https://example.org.\n- A **launch check** (#34; #50).\n"
                .. "- A launch check (#34; [#50](https://github.com/o/r/issues/50#issuecomment-1)).\n"))
            assert.are.equal(1, #factProblems("- A fact with no source.\n"))
            assert.are.equal(1, #factProblems("- A launch check (#34).\n"))
            assert.are.equal(1, #factProblems("- A launch check (#500).\n"))
            assert.are.equal(1, #factProblems("- A launch check (#34; [#50]()).\n"))
            assert.are.equal(1, #factProblems("From #32 ([its comment]()).\n"))
            assert.are.same({}, factProblems("- A launch check (#34; [#50](https://github.com/o/r/issues/50#c-1)).\n"))
            assert.are.equal(1, #factProblems("- A launch check ([#50](https://github.com/o/r/issues/32#c-1)).\n"))
            assert.are.equal(1, #factProblems("- Fixed in [#94](https://github.com/o/r/pull/93).\n"))
            assert.are.same({}, factProblems("- A launch check (#34; [its item](https://github.com/o/r/issues/50#c-1)).\n"))
            assert.are.equal(1, #factProblems("- A launch check ([its item](https://github.com/o/r/issues/32#c-1)).\n"))
            assert.are.equal(1, #factProblems("- A fact ([#34]( )).\n"))
        end)

        it("report a bullet whose only reference is its #50 launch-check link as no source (#118)", function()
            for _, onlyFifty in ipairs({
                "- A **launch check** (#50).\n",
                "- A launch check ([#50](https://github.com/o/r/issues/50#issuecomment-1)).\n",
                "- A launch check ([its item](https://github.com/o/r/issues/50#c-1)).\n",
                "- A launch check (https://github.com/o/r/issues/50#c-1).\n",
                "- A launch check ([#50](https://github.com/o/r/issues/50)), and #50 again.\n",
                "  - a nested launch check (#50).\n",
            }) do
                assert.are.same({ "no source: " .. onlyFifty:sub(1, -2) }, factProblems(onlyFifty), onlyFifty)
            end
            for _, sourced in ipairs({
                "- A launch check (#50). Source: #32.\n",
                "- A launch check (#50). Source: [#32](https://github.com/o/r/issues/32#c-1).\n",
                "- A launch check (#50). Source: [a guide](https://example.org/guide).\n",
                "- A launch check ([#50](https://github.com/o/r/issues/50#c-1)), from #500.\n",
                "- A launch check (#50), from https://github.com/o/r/issues/500.\n",
            }) do
                assert.are.same({}, factProblems(sourced), sourced)
            end
        end)

        it("check nested bullets like any other", function()
            assert.are.equal(1, #factProblems("- A fact (#34):\n  - and one with no source.\n"))
            assert.are.equal(1, #factProblems("- Facts (#34):\n  - a launch check (#34).\n"))
        end)

        it("check every row of a table for its source", function()
            local tableText = "| Quirk | Workaround | Source |\n|---|---|---|\n| It wraps. | Measure it. | #91 |\n"
                .. "| It logs twice. | Drop repeats. | `ui-sim.yml` |\n"
            assert.are.same({}, factProblems(tableText))
            local unsourced = tableText:gsub("| #91 |", "|  |")
            assert.are_not.equal(tableText, unsourced)
            assert.are.equal(1, #factProblems(unsourced))
            assert.are.equal(1, #factProblems(tableText .. "| A launch check. | None. | #34 |\n"))
            assert.are.equal(1, #factProblems(tableText .. "| It's slow. | Wait. |  |   \n"))
            assert.are.equal(1, #factProblems(tableText .. "|  |  |  |\n"))
            assert.are.equal(1, #factProblems(tableText .. "| --- | --- |  |\n"))
        end)

        it("report a table row whose source cell holds only its #50 launch-check link as no source (#122)", function()
            local tableText = "| Quirk | Workaround | Source |\n|:---|---:|:-:|\n| It wraps. | Measure it. | #91 |\n"
            assert.are.same({}, factProblems(tableText))
            for _, onlyFifty in ipairs({
                "#50",
                " #50 ",
                "#50, #50",
                "[#50](https://github.com/o/r/issues/50#issuecomment-1)",
                "[its item](https://github.com/o/r/issues/50#c-1)",
                "https://github.com/o/r/issues/50#c-1",
                "[#50](https://github.com/o/r/issues/50) (#50)",
            }) do
                local row = "| A launch check. | None. | " .. onlyFifty .. " |"
                assert.are.same({ "no source: " .. row }, factProblems(tableText .. row .. "\n"), onlyFifty)
            end
            for _, sourced in ipairs({
                "#50, #116",
                "#116; #50",
                "#500",
                "#5000",
                "[#50](https://github.com/o/r/issues/50#c-1), [#32](https://github.com/o/r/issues/32#c-1)",
                "#50, [a guide](https://example.org/guide)",
                "#50, `ui-sim.yml`",
                "https://github.com/o/r/issues/500",
            }) do
                local row = "| A launch check (#50). | None. | " .. sourced .. " |"
                assert.are.same({}, factProblems(tableText .. row .. "\n"), sourced)
            end
        end)
    end)

    for _, name in ipairs(AGENTS) do
        it(".claude/agents/" .. name .. ".md names its required output, ending in APPROVED or CHANGES REQUESTED,"
            .. " and cites every lesson", function()
            assert.are.same({}, agentProblems(wow.readFile(".claude/agents/" .. name .. ".md"), name))
        end)
    end

    for _, name in ipairs(SKILLS) do
        it(".claude/skills/" .. name .. " is a skill named " .. name, function()
            assert.are.same({}, skillProblems(wow.readFile(".claude/skills/" .. name .. "/SKILL.md"), name))
        end)
    end

    -- Files of game and simulator facts: every bullet has its source.
    for _, path in ipairs({ "docs/forever-facts.md", "docs/ui-simulator.md" }) do
        it(path .. " gives every fact a source other than its #50 link, and links #50 for every launch check",
            function()
            assert.are.same({}, factProblems(wow.readFile(path)))
        end)
    end

    -- The simulated client's guide describes the code: that's its source.
    it("docs/simulated-client.md names spec/support/wow.lua as its source, and links #50 for every launch check",
        function()
            local text = wow.readFile("docs/simulated-client.md")
            assert.is_truthy(text:find("**Source:** everything here describes `spec/support/wow.lua`", 1, true))
            for _, problem in ipairs(factProblems(text)) do
                assert.is_falsy(problem:find("^launch check"), problem)
            end
        end)

    it("CLAUDE.md sends reviews to the agents and points to every knowledge file and skill", function()
        local text = wow.readFile("CLAUDE.md")
        for _, name in ipairs(AGENTS) do assert.is_truthy(text:find("`" .. name .. "`", 1, true), name) end
        for _, name in ipairs(SKILLS) do assert.is_truthy(text:find("`" .. name .. "`", 1, true), name) end
        for _, path in ipairs(DOCS) do assert.is_truthy(text:find("(" .. path .. ")", 1, true), path) end
        assert.is_truthy(text:find("**Keep them current:**", 1, true), "the keep-current rule")
    end)

    -- GitHub deletes merged branches and #115 deletes screenshot branches, so
    -- sessions flag only the ones that outlived their PR, or have none (#119).
    it("CLAUDE.md and the coordinator skill flag only stale branches, and keep the never-delete"
        .. " and never-force-push rules", function()
        local claude = wow.readFile("CLAUDE.md")
        local coordinator = wow.readFile(".claude/skills/coordinator/SKILL.md")
        for name, text in pairs({ ["CLAUDE.md"] = claude, coordinator = coordinator }) do
            assert.is_falsy(text:find("any branches for the owner to delete", 1, true), name .. " lists merged branches")
            assert.is_falsy(text:find("branches it names for the owner", 1, true), name .. " lists merged branches")
            assert.is_truthy(text:find("still there after its PR merged or closed, or one with no PR", 1, true),
                name .. " flags a branch that outlived its PR or has none")
        end
        for _, rule in ipairs({
            "\n  2. Send the coordinator one line: `done: #<issue>, PR #<n> merged`, plus any step the owner still has"
                .. " to take (such as applying environment settings or running a workflow) and any stale branch.\n",
            "\n- **The owner merges.** Never merge, approve or delete branches. Ask before deleting anything. Leave stale"
                .. " branches for the owner, and say which they are.\n",
            "\n- **Force-pushing:** never. Push a rebased branch under a new name and flag the old one for the owner"
                .. " to delete.\n",
        }) do
            assert.is_truthy(claude:find(rule, 1, true), rule)
        end
        assert.is_truthy(coordinator:find("- **Never merges, approves or deletes:** not a PR, a branch, an issue"
            .. " or a comment.", 1, true), "the coordinator's never-delete rule")
        assert.is_truthy(wow.readFile(".claude/skills/after-merge/SKILL.md"):find("Never force-push.", 1, true),
            "after-merge's never-force-push rule")
    end)
end)
