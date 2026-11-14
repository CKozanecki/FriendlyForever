-- Spec: #49, #50, #65, #77, #80, #82, #89, #95, #103, #104, #106, #117, #118, #119, #122, #127, #130, #147, #153, #154, #170, #172, #173, #178, #182, #186, #197, #215, #218, #226, #229, #241, #242, #261, #318, #160, #309, #310
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

    -- #261: a pull request that changes the TOC version is a release PR, and
    -- its notes must hold every changelog note. Runs the step's own script in
    -- a scratch repository with the real Makefile and release-notes.sh.
    describe("a release PR's notes leave no changelog note behind (#261)", function()
        local script

        setup(function()
            local job = jobWith(select(2, parseWorkflow(path)), "make release%-notes")
            local step = job.steps[indexOf(job.steps, "make release%-notes")]
            assert.is_truthy(step.text:find("BASE: ${{ github.event.pull_request.base.sha || github.event.before }}", 1, true),
                "the step doesn't compare with the pull request's base")
            script = step.text:match("run: |\n(.*)$"):gsub("\n          ", "\n"):gsub("^%s+", "")
        end)

        -- Commits a TOC at version `from`, then one at `to` with the given
        -- fragments, and runs the step against the first as its base.
        local function step(from, to, fragments, base)
            local dir = io.popen("mktemp -d"):read("*l")
            local root = wow.ROOT:sub(1, 1) == "/" and wow.ROOT or (io.popen("pwd"):read("*l") .. "/" .. wow.ROOT)
            local body = io.open(dir .. "/step.sh", "wb")
            body:write(script)
            body:close()
            local setup = table.concat({
                "set -e", "cd '" .. dir .. "'", "mkdir repo scripts", "cd repo", "git init -q .",
                "git config user.email t@example.invalid", "git config user.name t",
                "cp '" .. root .. "Makefile' . && mkdir scripts && cp '" .. root .. "scripts/release-notes.sh' scripts/",
                "printf '# Changelog\\n\\n## " .. from .. "\\n\\n- x (#1)\\n' > CHANGELOG.md",
                "printf '## Version: " .. from .. "\\n' > FriendlyForever.toc",
                "git add -A && git commit -qm base",
                "printf '## Version: " .. to .. "\\n' > FriendlyForever.toc",
                "mkdir -p changes",
            }, "\n")
            for _, name in ipairs(fragments) do
                setup = setup .. "\nprintf -- '- y (#5)\\n' > changes/" .. name
            end
            setup = setup .. "\ngit add -A && git commit -qm head\n"
            setup = setup .. "BASE=" .. (base or "$(git rev-parse HEAD~1)") .. " bash -e ../step.sh\n"
            local p = io.popen("bash -c '" .. setup:gsub("'", "'\\''") .. "' 2>&1; echo rc=$?")
            local out = p:read("*a")
            p:close()
            os.execute("rm -rf '" .. dir .. "'")
            return out, tonumber(out:match("rc=(%d+)\n$"))
        end

        -- The step reads the base commit's TOC; a shallow checkout can't, and
        -- would quietly skip the check (#262's testing review).
        it("runs in a job that checks out the whole history, so the base can be read (black)", function()
            local job = jobWith(select(2, parseWorkflow(path)), "make release%-notes")
            local checkout = job.steps[indexOf(job.steps, "actions/checkout@")]
            assert.is_truthy(checkout and checkout.text:find("\n%s*fetch%-depth: 0\n"),
                job.name .. "'s checkout is shallow: the release PR check can't read the base TOC")
        end)

        -- The amended criterion (owner, 2026-11-12): the PR template's tick box
        -- is the check that a user-visible PR has a note, so its whole line is pinned.
        it("the PR template asks a user-visible change for its changes/<issue>.md (black)", function()
            local template = wow.readFile(".github/pull_request_template.md")
            local line = template:match("\n(%- %[ %] User%-visible change:[^\n]*)\n")
            assert.are.equal("- [ ] User-visible change: added its note as `changes/<issue>.md`, one bullet ending with its "
                .. "issue(s), e.g. `(#123)` or `(#27, #52)` ([Changelog notes](https://github.com/CKozanecki/FriendlyForever/"
                .. "blob/main/CONTRIBUTING.md#changelog-notes)); `CHANGELOG.md` itself is changed only by a release PR", line)
            assert.is_nil(template:find("### Unreleased", 1, true), "the template still asks for an Unreleased line")
            assert.is_truthy(wow.readFile("CONTRIBUTING.md"):find("\n### Changelog notes\n", 1, true),
                "the template links to a Changelog notes section that isn't there")
        end)

        it("fails when the TOC version changes and a fragment is left (black)", function()
            local out, code = step("1.0.0", "1.1.0", { "5.md" })
            assert.are_not.equal(0, code, out)
            assert.is_truthy(out:find("make changelog", 1, true), out)
        end)

        it("passes a release PR that gathered everything (white)", function()
            local out, code = step("1.0.0", "1.1.0", {})
            assert.are.equal(0, code, out)
        end)

        it("passes an ordinary PR with a fragment, and a push with no known base (white)", function()
            local out, code = step("1.0.0", "1.0.0", { "5.md" })
            assert.are.equal(0, code, out)
            out, code = step("1.0.0", "1.1.0", { "5.md" }, "0000000000000000000000000000000000000000")
            assert.are.equal(0, code, out)
        end)
    end)

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

    -- #218: the tests run in parallel shards and one job, `check`, is the
    -- single required pass/fail. The job's name is the check's name on main.
    it("reports one required check named check, which passes only when lint, packaging and every shard did", function()
        local jobs = parseWorkflow(path)
        local check = jobs.check
        assert.is_truthy(check, "CI has no job named check, the check main requires")
        assert.is_truthy(check.text:find("needs:%s*%[%s*lint%-package%s*,%s*test%s*%]"),
            "check doesn't wait for lint-package and test")
        -- Without it a failed or cancelled job would skip check, and a
        -- skipped required check counts as passing.
        assert.is_truthy(check.text:find("if:%s*${{%s*always%(%)%s*}}"), "check doesn't run when a job before it fails")
        for _, job in ipairs({ "lint-package", "test" }) do
            assert.is_truthy(check.text:find('"$' .. (job == "test" and "TESTS" or "LINT_PACKAGE") .. '" = success', 1, true),
                "check doesn't require " .. job .. " to be success")
            assert.is_truthy(check.text:find("needs." .. job .. ".result", 1, true), "check doesn't read " .. job .. "'s result")
        end
        assert.is_truthy(check.text:find('test-shards.sh check "$SHARDS"', 1, true), "check doesn't verify the shards cover every spec")
    end)

    it("runs the specs in as many shards as it says, each a different slice, with the release packager once", function()
        local ci = wow.readFile(path)
        local jobs, order = parseWorkflow(path)
        local shards = tonumber(ci:match("\n  SHARDS:%s*(%d+)"))
        assert.is_truthy(shards and shards >= 2, "CI doesn't say how many shards")
        local listed = jobs.test.text:match("shard:%s*%[([^%]]*)%]")
        local expected = {}
        for i = 1, shards do expected[#expected + 1] = tostring(i) end
        assert.are.equal(table.concat(expected, ", "), listed, "the matrix isn't shards 1 to SHARDS")
        assert.is_truthy(jobs.test.text:find([[SPECS="$(scripts/test-shards.sh files "$SHARDS" "$SHARD" | tr '\n' ' ')"]], 1, true),
            "a shard doesn't run its own slice")
        assert.is_truthy(jobs.test.text:find("fail%-fast:%s*false"), "one failing shard hides the others")
        local packagers = 0
        for _, job in ipairs(order) do
            if job.text:find("BigWigsMods/packager@") then packagers = packagers + 1 end
            -- Every job that runs a Lua tool installs it the same way, from the cache.
            if job.text:find("make test") or job.text:find("make lint") then
                assert.is_truthy(job.text:find("make setup", 1, true), job.name .. " runs a tool without make setup")
            end
        end
        assert.are.equal(1, packagers, "the release packager must run once, not once per shard")
        assert.is_falsy(jobs.test.text:find("BigWigsMods"), "a shard builds with the release packager")
        assert.is_truthy(ci:find("cancel%-in%-progress:%s*true"), "a newer push doesn't cancel the older run")
    end)

    -- The gate: nothing may soften it, and its script must say no to anything
    -- but success (the testing review, #218).
    it("lets check pass only when lint, packaging and every shard succeeded, and nothing softens it (black)", function()
        local jobs = parseWorkflow(path)
        for _, name in ipairs({ "check", "lint-package", "test" }) do
            assert.is_falsy(jobs[name].text:find("continue%-on%-error"), name .. " can fail without failing CI")
        end
        assert.is_truthy(jobs.check.text:find('\n%s*run: scripts/test%-shards%.sh check "%$SHARDS"\n'),
            "the shard check isn't exactly its command, so it could be softened")
        local script = jobs.check.text:match("run: |\n(.*)$")
        assert.is_truthy(script and script:find('"$TESTS" = success', 1, true), "couldn't find the result check")
        local dir = io.popen("mktemp -d"):read("*l")
        local file = io.open(dir .. "/gate.sh", "w")
        file:write((script:gsub("\n          ", "\n"):gsub("^%s+", "")))
        file:close()
        local function gate(lint, tests)
            return os.execute("cd '" .. dir .. "' && LINT_PACKAGE=" .. lint .. " TESTS=" .. tests .. " bash -e gate.sh >/dev/null 2>&1")
        end
        assert.are.equal(0, gate("success", "success"))
        for _, bad in ipairs({ "failure", "skipped", "cancelled", "" }) do
            assert.are_not.equal(0, gate("success", "'" .. bad .. "'"), "tests " .. bad .. " passed the gate")
            assert.are_not.equal(0, gate("'" .. bad .. "'", "success"), "lint " .. bad .. " passed the gate")
        end
        os.execute("rm -rf '" .. dir .. "'")
    end)

    -- Without $(SPECS) every shard would quietly run all the specs.
    it("makes each shard run only its own spec files (white)", function()
        local function recipe(args)
            local p = io.popen("cd '" .. wow.ROOT .. "' && env -u SPECS -u MAKEFLAGS -u MAKELEVEL -u MFLAGS make -n test TOOLS=/nowhere " .. args .. " 2>&1")
            local out = p:read("*a")
            p:close()
            return out
        end
        local some = recipe("SPECS='spec/a_spec.lua spec/b_spec.lua'")
        assert.is_truthy(some:find("busted\" spec/a_spec.lua spec/b_spec.lua", 1, true), some)
        assert.is_falsy(recipe(""):find("_spec", 1, true), "make test with no SPECS names spec files")
    end)
end)

describe("Test shards", function()
    local function run(env)
        local p = io.popen("cd '" .. wow.ROOT .. "' && " .. env .. " scripts/test-shards.sh check 4 2>&1; echo rc=$?")
        local out = p:read("*a")
        p:close()
        return out, tonumber(out:match("rc=(%d+)"))
    end

    -- #218: a spec file that is in no shard is never run; one in two runs twice.
    it("put every spec file in exactly one shard (white)", function()
        local out, rc = run("env")
        assert.are.equal(0, rc, out)
        local p = io.popen("cd '" .. wow.ROOT .. "' && find spec -type f -name '*_spec*.lua' | wc -l")
        local total = tonumber(p:read("*a"))
        p:close()
        assert.is_true(total > 50, "found too few spec files")
        assert.is_truthy(out:find("all " .. total .. " spec files", 1, true), out)
    end)

    it("fail when a spec file is in no shard or in two (black)", function()
        local out, rc = run("TEST_SHARDS_FAULT=drop")
        assert.are_not.equal(0, rc, "a file in no shard went unnoticed")
        assert.is_truthy(out:find("in no shard", 1, true), out)
        out, rc = run("TEST_SHARDS_FAULT=dup")
        assert.are_not.equal(0, rc, "a file in two shards went unnoticed")
        assert.is_truthy(out:find("more than one shard", 1, true), out)
        out, rc = run("TEST_SHARDS_FAULT=extra")
        assert.are_not.equal(0, rc, "a file that isn't a spec went unnoticed")
        assert.is_truthy(out:find("not a spec file", 1, true), out)
    end)

    it("refuse shard numbers that make no sense (black)", function()
        for _, args in ipairs({ "files 4 0", "files 4 5", "files 0 1", "files x 1", "files 4", "bogus" }) do
            local p = io.popen("cd '" .. wow.ROOT .. "' && scripts/test-shards.sh " .. args .. " >/dev/null 2>&1; echo $?")
            local rc = tonumber(p:read("*a"))
            p:close()
            assert.are_not.equal(0, rc, args .. " was accepted")
        end
    end)

    it("split the same way every time, with the slowest file alone in the lightest shard", function()
        local function slice(n)
            local p = io.popen("cd '" .. wow.ROOT .. "' && scripts/test-shards.sh files 4 " .. n)
            local out = p:read("*a")
            p:close()
            return out
        end
        for n = 1, 4 do assert.are.equal(slice(n), slice(n)) end
        assert.is_truthy(slice(1):find("spec/guildhellos_spec.lua", 1, true))
        assert.is_falsy(slice(1):find("spec/repo_spec.lua", 1, true))
    end)
end)

describe("UI simulator workflow", function()
    local path = ".github/workflows/ui-sim.yml"
    local text, jobs, order
    -- scripts/data/forever-spells.json's SHA-256: the one the simulator's own
    -- spec records for its 72-spell selection (#209, #160).
    -- spec/bufftable_spec.lua checks the file has it.
    local COMMITTED_SPELLS_SHA256 = "13122873d813481e85815946ddf964068b04132d4d2b2b44ba5ce61491595ad0"

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

    -- #218: the simulator runs only when a file that can change what players
    -- see changes. The decision is made inside the workflow, never by a
    -- `paths:` filter, which would leave a required check pending.
    describe("runs only for UI changes (#218)", function()
        local function onBlock()
            return text:match("^(.-)\njobs:"):match("\non:\n(.-)\n[%w]") or ""
        end

        it("decides in a job, never with a paths filter (black)", function()
            assert.is_falsy(text:match("^(.-)\njobs:"):find("paths:"), "a paths filter leaves a required check pending")
            assert.is_truthy(onBlock():find("pull_request:"), "no longer runs on pull requests")
            assert.is_truthy(onBlock():find("push:"), "no longer runs on pushes to main")
            assert.is_truthy(onBlock():find("workflow_dispatch:"), "can't be started by hand")
            assert.is_truthy(jobs.changes, "no job decides whether a UI file changed")
        end)

        it("skips the simulator jobs, and the publisher, only when the answer is false (white)", function()
            local sim = jobs.simulator
            assert.is_truthy(sim.text:find("needs:%s*changes"), "the simulator doesn't wait for the decision")
            -- Not == 'true': an empty answer (the deciding job failed) must run it.
            assert.is_truthy(sim.text:find("if:%s*${{%s*needs%.changes%.outputs%.ui != 'false'%s*}}"),
                "the simulator isn't skipped on a false answer, or isn't run on an empty one")
            for _, name in ipairs({ "ui-sim", "screenshots" }) do
                assert.is_truthy(jobs[name].text:find("needs:%s*simulator"), name .. " doesn't follow the simulator")
                assert.is_falsy(jobs[name].keys["if"], name .. " has its own condition, so it could run without a simulator")
            end
            -- !cancelled() runs a job whose needs were skipped; this one must not.
            local publish = jobs["publish-screenshots"].text
            assert.is_truthy(publish:find("needs.screenshots.result != 'skipped'", 1, true),
                "the publisher runs when the screenshots were skipped")
        end)

        it("gives each push to main its own run group, so one can't cancel another's (white)", function()
            assert.is_truthy(text:find("group: ui-sim-${{ github.event_name == 'push' && github.sha || github.ref }}", 1, true))
            assert.is_truthy(text:find("cancel%-in%-progress:%s*true"), "a newer pull request push doesn't replace the older run")
        end)

        it("gives the deciding job no write access, no secrets and nothing from the pull request to run (black)", function()
            local job = jobs.changes
            assert.is_falsy(job.keys.permissions, "the deciding job has its own permissions")
            assert.is_falsy(job.text:find("secrets%."), "the deciding job uses secrets")
            assert.is_truthy(job.text:find("persist%-credentials:%s*false"), "its checkout keeps the token")
            assert.is_truthy(job.text:find("continue%-on%-error:%s*true"), "it can fail CI")
            -- A file name only ever reaches the log with all but plain characters replaced.
            assert.is_truthy(job.text:find("tr %-c 'A%-Za%-z0%-9%._/%-' '%?'"), "a file name is printed as it is")
            for _, banned in ipairs({ "make ", "busted", "luacheck", "docker", "bash scripts", "%./" }) do
                assert.is_falsy(job.text:find(banned), "the deciding job runs " .. banned)
            end
        end)

        -- The UI files are the ones that create frames. A new one has to join
        -- the list, or its changes would skip the simulator.
        it("lists every root Lua file that creates a frame as a UI file (white)", function()
            local filter = jobs.changes.text:match("(Battleground%.lua.-Window%.lua)") or ""
            assert.is_truthy(filter:find("Options.lua", 1, true), "couldn't find the UI file list")
            local p = io.popen("cd '" .. wow.ROOT .. "' && grep -l CreateFrame *.lua")
            local found = 0
            for file in p:read("*a"):gmatch("[^\n]+") do
                found = found + 1
                assert.is_truthy(filter:find(file, 1, true), file .. " creates frames but isn't a UI file")
            end
            p:close()
            assert.is_true(found >= 8, "expected the files that create frames, found " .. found)
            for _, file in ipairs({ "OptionsIndex.lua", "Nameplates.lua", "Colours.lua", "BuffData.lua", "BuffRules.lua" }) do
                assert.is_truthy(filter:find(file, 1, true), file .. " is a UI file")
            end
        end)

        -- Runs the decision itself on a throw-away repository shaped like a
        -- pull request's merge commit (its first parent is the base).
        it("says true for a UI file, the workflow or a hand start, and false for logic and docs (white, black)", function()
            local script = jobs.changes.text:match("run: |\n(.-)\n\n") or jobs.changes.text:match("run: |\n(.*)$")
            assert.is_truthy(script and script:find("set %-u"), "couldn't find the deciding script")
            local dir = io.popen("mktemp -d"):read("*l")
            local body = io.open(dir .. "/decide.sh", "w")
            body:write((script:gsub("\n          ", "\n"):gsub("^%s+", "")))
            body:close()
            local function sh(command) return os.execute("cd '" .. dir .. "/repo' && ( " .. command .. " ) >/dev/null 2>&1") == 0 end
            local function answer(event, before)
                local out = io.popen("cd '" .. dir .. "/repo' && : > ../out && GITHUB_OUTPUT='" .. dir .. "/out' EVENT=" .. event
                    .. " BEFORE='" .. (before or "") .. "' bash -e ../decide.sh >/dev/null 2>&1; cat ../out"):read("*a")
                return out:match("ui=(%a+)")
            end
            local change = 0
            local function pullRequest(files)
                sh("git checkout -q -B base && git reset -q --hard root")
                sh("git checkout -q -B pr && git reset -q --hard root")
                for _, file in ipairs(files) do
                    change = change + 1
                    sh("mkdir -p $(dirname '" .. file .. "') && echo " .. change .. " >> '" .. file .. "'")
                end
                sh("git add -A && git commit -q -m change")
                sh("git checkout -q base && git merge -q --no-ff -m merge pr")
                return answer("pull_request")
            end
            os.execute("mkdir '" .. dir .. "/repo'")
            assert.is_true(sh("git init -q && git config user.email a@b && git config user.name a"
                .. " && mkdir uitests docs && echo 1 > Greeter.lua && echo 1 > Options.lua && echo 1 > docs/a.md"
                .. " && echo 1 > uitests/x.lua && git add -A && git commit -q -m root && git tag root"))
            local cases = {
                { { "Greeter.lua", "docs/a.md" }, "false" },
                { { "Greeter.lua", "Options.lua" }, "true" },
                -- The palette every colour comes from (the architecture review).
                { { "Colours.lua" }, "true" },
                -- They decide text the Buff Back tab shows (#226): one case each.
                { { "BuffData.lua" }, "true" },
                { { "BuffRules.lua" }, "true" },
                -- A file that creates frames, added by #43 after this list was written.
                { { "BuffList.lua" }, "true" },
                { { "uitests/x.lua" }, "true" },
                { { ".github/workflows/ui-sim.yml" }, "true" },
                { { "Media/a.tga" }, "true" },
                { { "Media/\195\169.tga" }, "true" },
                { { "FriendlyForever.toc" }, "true" },
                { { "Bindings.xml" }, "true" },
                { { ".pkgmeta" }, "true" },
                { { "scripts/package.sh" }, "true" },
                { { "scripts/ui-sim-harness.lua" }, "true" },
                -- The spell data check and the copy it checks against (#160).
                { { "scripts/sim-spell-check.py" }, "true" },
                { { "scripts/data/forever-spells.json" }, "true" },
                { { "scripts/other.sh", "Makefile" }, "false" },
                { { "docs/new.md", "spec/x_spec.lua", "CHANGELOG.md" }, "false" },
                -- Only the root files count, not a same-named file in a folder.
                { { "docs/Options.lua", "docs/notes.xml" }, "false" },
            }
            for _, case in ipairs(cases) do
                assert.are.equal(case[2], pullRequest(case[1]), table.concat(case[1], ", "))
            end
            assert.are.equal("true", answer("workflow_dispatch"))
            local function rev(ref) return io.popen("cd '" .. dir .. "/repo' && git rev-parse " .. ref):read("*l") end
            -- Doubt means it runs: no commit to compare with, a pull request
            -- with no parent (a shallow checkout), nothing changed.
            assert.are.equal("true", answer("push", "0000000000000000000000000000000000000000"))
            assert.are.equal("true", answer("push", ""))
            assert.are.equal("true", answer("push", "not-a-sha"))
            sh("git checkout -q -B base root")
            assert.are.equal("true", answer("pull_request"), "a pull request without a base commit skipped the simulator")
            assert.are.equal("true", answer("push", rev("HEAD")), "a push that changed nothing skipped the simulator")
            -- A push of several commits: the UI file changed in an earlier one.
            sh("git checkout -q -B main root && echo 2 >> Options.lua && git commit -qam ui && echo 3 >> Greeter.lua && git commit -qam logic")
            assert.are.equal("true", answer("push", rev("root")), "a UI file in the first of two commits was missed")
            assert.are.equal("false", answer("push", rev("HEAD^")), "a logic-only push ran the simulator")
            os.execute("rm -rf '" .. dir .. "'")
        end)

        -- #241: a UI file whose change can't change what players see (the TOC's
        -- version line, comments in a root Lua file) skips the simulator, and
        -- every doubt still runs it. Each case is a pull request on a
        -- throw-away repository whose files are written whole.
        it("skips a TOC version bump and comment-only Lua, and runs for anything else or any doubt (white, black)", function()
            local script = jobs.changes.text:match("run: |\n(.-)\n\n") or jobs.changes.text:match("run: |\n(.*)$")
            assert.is_truthy(script and script:find("comments_only", 1, true), "couldn't find the deciding script")
            -- GitHub runs a step with no shell: key as bash -e, and so does this test.
            -- Nowhere: a workflow- or job-level defaults: could set one too.
            assert.is_falsy(withoutComments(text):find("shell:"), "ui-sim.yml names a shell")
            local dir = io.popen("mktemp -d"):read("*l")
            local body = io.open(dir .. "/decide.sh", "w")
            body:write((script:gsub("\n          ", "\n"):gsub("^%s+", "")))
            body:close()
            local repo = dir .. "/repo"
            local function sh(command) return os.execute("cd '" .. repo .. "' && ( " .. command .. " ) >/dev/null 2>&1") == 0 end
            local function write(files)
                for name, content in pairs(files) do
                    if content == false then
                        sh("git rm -q '" .. name .. "'")
                    else
                        os.execute("mkdir -p \"$(dirname '" .. repo .. "/" .. name .. "')\"")
                        local f = io.open(repo .. "/" .. name, "wb")
                        f:write(content)
                        f:close()
                    end
                end
            end
            local function answer(event, before)
                local out = io.popen("cd '" .. repo .. "' && : > ../out && GITHUB_OUTPUT='" .. dir .. "/out' EVENT=" .. event
                    .. " BEFORE='" .. (before or "") .. "' bash -e ../decide.sh >/dev/null 2>&1; cat ../out"):read("*a")
                return out:match("ui=(%a+)")
            end
            local function pullRequest(files)
                sh("git checkout -q -B base && git reset -q --hard root")
                sh("git checkout -q -B pr && git reset -q --hard root")
                write(files)
                sh("git add -A && git commit -q -m change")
                sh("git checkout -q base && git merge -q --no-ff -m merge pr")
                return answer("pull_request")
            end
            local toc = "## Interface: 16001\n## Title: Friendly Forever\n## Version: 1.0.1\n\nCore.lua\nBuffData.lua\n"
            local data = "-- The buffs.\nlocal a = 1 -- one\n\nlocal s = \"x -- y\"\nlocal q = 'q' -- it's\nreturn a\n"
            os.execute("mkdir '" .. repo .. "'")
            assert.is_true(sh("git init -q && git config user.email a@b && git config user.name a"))
            write({ ["FriendlyForever.toc"] = toc, ["BuffData.lua"] = data, ["Options.lua"] = "-- c\nlocal t = 1\n",
                ["Core.lua"] = "return 1\n", ["Window.lua"] = "local w = 1\r\nreturn w\r\n",
                ["Bindings.xml"] = "<Bindings>\n<!-- a -->\n</Bindings>\n", ["CHANGELOG.md"] = "## 1.0.1\n",
                ["uitests/x.lua"] = "-- c\nlocal x\n" })
            assert.is_true(sh("git add -A && git commit -q -m root && git tag root"))
            local function edit(source, from, to)
                local i, j = source:find(from, 1, true)
                assert.is_truthy(i, "the test's file has no " .. from)
                return source:sub(1, i - 1) .. to .. source:sub(j + 1)
            end
            local bumped = edit(toc, "1.0.1", "1.0.2")
            local cases = {
                -- The release PR: the version line and the changelog.
                { "version bump", { ["FriendlyForever.toc"] = bumped, ["CHANGELOG.md"] = "## 1.0.2\n" }, "false" },
                { "version bump that also changes every line ending", { ["FriendlyForever.toc"] = bumped:gsub("\n", "\r\n") }, "true" },
                { "Interface line", { ["FriendlyForever.toc"] = edit(toc, "16001", "16002") }, "true" },
                { "version and Interface", { ["FriendlyForever.toc"] = edit(bumped, "16001", "16002") }, "true" },
                { "a file line", { ["FriendlyForever.toc"] = bumped .. "Water.lua\n" }, "true" },
                { "a file line removed", { ["FriendlyForever.toc"] = edit(bumped, "BuffData.lua\n", "") }, "true" },
                { "the title", { ["FriendlyForever.toc"] = edit(bumped, "Forever\n", "Forever!\n") }, "true" },
                { "a line that says Version:", { ["FriendlyForever.toc"] = bumped .. "## Notes: Version: 2\n" }, "true" },
                -- A carriage return could start a line the game reads as a file.
                { "a file line behind the version line", { ["FriendlyForever.toc"] = edit(bumped, "1.0.2\n", "1.0.2\rWater.lua\n") }, "true" },
                -- Comments in a UI Lua file (#239 changed BuffData.lua's).
                { "a comment line", { ["BuffData.lua"] = edit(data, "The buffs.", "The buffs we know.") }, "false" },
                { "a comment at the end of a line", { ["BuffData.lua"] = edit(data, "-- one", "-- the first") }, "false" },
                { "a comment added", { ["BuffData.lua"] = edit(data, "return a", "return a -- done") }, "false" },
                { "comment and blank lines added", { ["BuffData.lua"] = "\n-- New.\n\n" .. data .. "\n-- End.\n" }, "false" },
                { "a comment added, Windows line endings", { ["Window.lua"] = "local w = 1 -- w\r\nreturn w\r\n" }, "false" },
                { "a comment removed", { ["BuffData.lua"] = edit(data, "-- The buffs.\n", "") }, "false" },
                { "comments in two files and the version",
                    { ["BuffData.lua"] = edit(data, "-- one", "-- 1"), ["Options.lua"] = "-- d\nlocal t = 1\n",
                        ["FriendlyForever.toc"] = bumped }, "false" },
                { "code", { ["BuffData.lua"] = edit(data, "local a = 1", "local a = 2") }, "true" },
                { "code with a minus", { ["Core.lua"] = "return 1 - 1\n" }, "true" },
                { "a -- inside a string", { ["BuffData.lua"] = edit(data, "x -- y", "x -- z") }, "true" },
                { "a comment after a quote", { ["BuffData.lua"] = edit(data, "it's", "it is") }, "true" },
                { "code commented out", { ["BuffData.lua"] = edit(data, "return a", "-- return a") }, "true" },
                { "code moved into a comment's line", { ["BuffData.lua"] = edit(data, "-- The buffs.", "local b -- The buffs.") }, "true" },
                { "indentation", { ["BuffData.lua"] = edit(data, "return a", "  return a") }, "true" },
                { "comments and code in two files",
                    { ["BuffData.lua"] = edit(data, "-- one", "-- 1"), ["Options.lua"] = "-- c\nlocal t = 2\n" }, "true" },
                { "version bump and code", { ["FriendlyForever.toc"] = bumped, ["Core.lua"] = "return 2\n" }, "true" },
                -- Doubt: long brackets, a line ending in a backslash, a file
                -- with no other side, a UI Lua file outside the root.
                { "a long comment", { ["BuffData.lua"] = data .. "--[[ note ]]\n" }, "true" },
                { "a long string", { ["BuffData.lua"] = data .. "-- [=[ x ]=]\n" }, "true" },
                { "a backslash at a line's end", { ["BuffData.lua"] = data .. "-- \\\n" }, "true" },
                -- Lua reads a lone carriage return as a line break, so x = 2 is code.
                { "a carriage return inside a line", { ["Window.lua"] = "local w = 1 -- w\rw = 2\r\nreturn w\r\n" }, "true" },
                -- Bash drops a NUL byte from what it reads, which would hide this change.
                { "a NUL byte", { ["BuffData.lua"] = edit(data, "x -- y", "x -\0- y") }, "true" },
                { "a deleted UI file", { ["Options.lua"] = false }, "true" },
                { "a new UI file of comments", { ["Water.lua"] = "-- Water.\n" }, "true" },
                { "a new TOC", { ["Other.toc"] = "## Version: 1\n" }, "true" },
                -- Only Lua files are read for comments: any change to XML runs.
                { "an XML comment", { ["Bindings.xml"] = "<Bindings>\n<!-- b -->\n</Bindings>\n" }, "true" },
                { "a comment in a scenario", { ["uitests/x.lua"] = "-- d\nlocal x\n" }, "true" },
            }
            for _, case in ipairs(cases) do
                assert.are.equal(case[3], pullRequest(case[2]), case[1])
            end
            -- A long bracket in the base fails open too, even when the change is a comment.
            sh("git checkout -q -B main root")
            write({ ["Options.lua"] = "local t = 1\n-- [[ c\n" })
            sh("git commit -qam longbase")
            local longBase = io.popen("cd '" .. repo .. "' && git rev-parse HEAD"):read("*l")
            -- Without its long bracket, the old version up to that line reads the same as the new one.
            write({ ["Options.lua"] = "local t = 1\n-- d\n" })
            sh("git commit -qam longcomment")
            assert.are.equal("true", answer("push", longBase), "a long bracket in either version skipped the simulator")
            -- A NUL byte in the old version only: bash would drop it and read the two the same.
            sh("git checkout -q -B main root")
            write({ ["BuffData.lua"] = edit(data, "x -- y", "x -\0- y") })
            sh("git commit -qam nulbase")
            local nulBase = io.popen("cd '" .. repo .. "' && git rev-parse HEAD"):read("*l")
            write({ ["BuffData.lua"] = data })
            sh("git commit -qam nulgone")
            assert.are.equal("true", answer("push", nulBase), "a NUL byte in the old version skipped the simulator")
            -- A carriage return inside the old TOC's version line could hide a file line the bump removes.
            sh("git checkout -q -B main root")
            write({ ["FriendlyForever.toc"] = edit(toc, "1.0.1\n", "1.0.1\rWater.lua\n") })
            sh("git commit -qam crbase")
            local crBase = io.popen("cd '" .. repo .. "' && git rev-parse HEAD"):read("*l")
            write({ ["FriendlyForever.toc"] = bumped })
            sh("git commit -qam crgone")
            assert.are.equal("true", answer("push", crBase), "a carriage return in the old TOC skipped the simulator")
            -- A push to main compares with the commit before it.
            sh("git checkout -q -B main root")
            write({ ["FriendlyForever.toc"] = bumped, ["BuffData.lua"] = edit(data, "-- one", "-- 1") })
            sh("git commit -qam release")
            assert.are.equal("false", answer("push", io.popen("cd '" .. repo .. "' && git rev-parse root"):read("*l")),
                "a push of a version bump and a comment ran the simulator")
            os.execute("rm -rf '" .. dir .. "'")
        end)
    end)

    it("never fails CI: every job is report only", function()
        assert.is_true(#order >= 3, "expected the scenario, screenshot and publish jobs")
        for _, job in ipairs(order) do
            -- The job's own key: a step's continue-on-error doesn't cover the job.
            local key = "\n" .. (" "):rep(job.keyIndent) .. "continue%-on%-error:%s*true"
            assert.is_truthy(job.text:find(key), job.name .. " can fail CI")
        end
    end)

    it("pins the sources and the build and render bases exactly", function()
        local function pinned(prefix, digits)
            return text:find("\n%s*" .. prefix .. ("%x"):rep(digits) .. "%s") ~= nil
        end
        assert.is_true(pinned("SIM_COMMIT: ", 40), "the simulator source isn't pinned to a commit")
        assert.is_true(pinned("BLIZZARD_UI_COMMIT: ", 40), "Blizzard's UI isn't pinned to a commit")
        assert.is_true(pinned("BUILD_BASE: rust@sha256:", 64), "the build image's base isn't pinned by digest")
        assert.is_true(pinned("RENDER_BASE: debian@sha256:", 64), "the render image's base isn't pinned by digest")
        assert.is_falsy(text:lower():find("uses:%s*osso/"), "uses the simulator project's own Action")

        -- The pins are used: every image built starts from one of them, and
        -- the fetched sources are checked against theirs.
        local bases = {}
        for base in text:gmatch("\n%s*FROM%s+(%S+)") do bases[#bases + 1] = base end
        -- The build image, the spell data step's proxy, and one render
        -- image in each job that runs the simulator.
        assert.are.same({ "$BUILD_BASE", "$RENDER_BASE", "$RENDER_BASE", "$RENDER_BASE" }, bases)
        assert.is_truthy(text:find('rev-parse HEAD)" = "$SIM_COMMIT"', 1, true), "the simulator's commit isn't checked")
        assert.is_truthy(text:find('rev-parse HEAD)" = "$BLIZZARD_UI_COMMIT"', 1, true), "Blizzard's commit isn't checked")
        -- #160: Blizzard's UI pin is the one the simulator's own source names
        -- for the profile, at the version it names, and its tree is exactly
        -- the simulator's file list.
        assert.is_truthy(text:find('pin="$RUNNER_TEMP/sim/data/blizzard-ui-builds/$SIM_PROFILE.json"', 1, true),
            "the pin isn't read from the simulator's source")
        assert.is_truthy(text:find([[grep -qF "\"gethe_revision\": \"$BLIZZARD_UI_COMMIT\"" "$pin"]], 1, true),
            "Blizzard's commit isn't checked against the simulator's own pin")
        assert.is_truthy(text:find([[grep -qF "\"version\": \"$BLIZZARD_UI_VERSION\"" "$pin"]], 1, true),
            "Blizzard's version isn't checked against the simulator's own pin")
        assert.is_truthy(text:find('manifest="$RUNNER_TEMP/sim/data/blizzard-ui-files/$SIM_PROFILE.txt"', 1, true),
            "the file list isn't the profile's")
        assert.is_truthy(text:find('diff -u <(LC_ALL=C sort "$manifest")', 1, true), "the tree isn't checked against the file list")
    end)

    -- Building and running the simulator have no network. Two containers
    -- have some, and neither builds or runs the simulator: cargo fetch, which
    -- downloads the locked crates and runs none of their code, and the spell
    -- data download (#160), which reaches only a proxy. The proxy is ours.
    local function kind(command)
        if command:find("ff%-build cargo fetch %-%-locked%s*$") then return "fetch" end
        if command:find("%sff%-proxy tinyproxy %-d %-c /proxy/tinyproxy%.conf%s*$") then return "proxy" end
        if command:find("%sff%-build /cli/wow%-cli casc sync%-forever%-spells %-%-source cdn %-%-output /spells/spells%.json%s") then
            return "spells"
        end
        return "sandboxed"
    end

    it("sandboxes every container: no capabilities, read-only sources, network only to download crates and spell data", function()
        local found, builds = 0, 0
        local count = { fetch = 0, proxy = 0, spells = 0, sandboxed = 0 }
        for _, job in ipairs(order) do
            for _, command in ipairs(dockerRuns(job)) do
                found = found + 1
                local what = kind(command)
                count[what] = count[what] + 1
                for _, flag in ipairs({ "--cap-drop ALL", "--security-opt no-new-privileges" }) do
                    assert.is_truthy(command:find(flag, 1, true), job.name .. ": docker run without " .. flag)
                end
                -- Ways out of the sandbox. Mounts are only ever -v, so the
                -- check below sees them all.
                for _, banned in ipairs({ "%-%-privileged", "docker%.sock", "%-%-net[%w]*[ =]host", "%-%-pid[ =]",
                    "%-%-ipc", "%-%-userns", "%-%-uts", "%-%-cap%-add", "%-%-device", "unconfined", "%-%-mount",
                    "%-%-volume", "%-%-add%-host", "%-%-dns", "%-%-link", "%-%-publish", "%s%-p%s", "%s%-P%s" }) do
                    assert.is_falsy(command:find(banned), job.name .. ": docker run with " .. banned)
                end
                if what == "sandboxed" then
                    assert.is_truthy(command:find("--network none", 1, true), job.name .. ": docker run with network")
                elseif what == "spells" then
                    -- Its own network, which has no route out.
                    assert.is_truthy(command:find("%-%-network ff%-cdn%s"), "the spell data download isn't on the closed network")
                    assert.are.equal(1, select(2, command:gsub("%-%-net", "")), "the spell data download names two networks")
                else
                    assert.is_falsy(command:find("--net", 1, true), job.name .. ": " .. what .. " names a network")
                end
                -- Only the simulator job's own steps may have any network.
                assert.is_true(what == "sandboxed" or job.name == "simulator", job.name .. " has a container with network")
                if command:find("cargo build", 1, true) then
                    builds = builds + 1
                    assert.are.equal("sandboxed", what)
                    assert.is_truthy(command:find("--offline", 1, true), "the simulator build may download")
                end
                -- Nothing with network runs the simulator, or builds anything.
                if what ~= "sandboxed" then
                    assert.is_falsy(command:find("wow-sim", 1, true), "the simulator runs with network")
                    assert.is_falsy(command:find("cargo build", 1, true) or command:find("cargo run", 1, true)
                        or command:find("cargo test", 1, true), "cargo runs the simulator's code with network")
                end
                for mount in command:gmatch("%-v%s+(%S+)") do
                    local writable = mount:find(":/shots\"?$") or mount:find(":/target\"?$")
                        or (what == "fetch" and mount:find(":/cargo\"?$"))
                        or (what == "spells" and mount:find(":/spells\"?$"))
                    assert.is_truthy(mount:find(":ro\"?$") or writable, job.name .. ": " .. mount .. " is mounted writable")
                end
            end
        end
        assert.is_true(found >= 7, "expected the simulator's docker runs")
        assert.are.equal(1, count.fetch, "expected one dependency download")
        assert.are.equal(1, count.proxy, "expected one proxy")
        assert.are.equal(1, count.spells, "expected one spell data download")
        assert.are.equal(1, builds, "expected the simulator to be built in a container")
        -- Anywhere outside a docker run, cargo would run on the runner.
        local outside = text:gsub("\\\n%s*", " "):gsub("docker run[^\n]*", "")
        assert.is_falsy(outside:find("%f[%w]cargo%s"), "cargo runs on the runner, outside a container")
    end)

    -- #160: the spell data download is the one run of the simulator's code
    -- with network. Its network has no route out; the proxy is the only way,
    -- and lets through only the listed hosts on port 443.
    describe("the spell data download (#160)", function()
        local step, job

        setup(function()
            job = jobs.simulator
            for _, candidate in ipairs(job.steps) do
                if candidate.text:find("name: Download Forever's spell data", 1, true) then step = candidate end
            end
        end)

        it("lists only Blizzard's discovery host and CDN, by plain name (black)", function()
            local hosts = {}
            for host in (text:match("\n%s*SPELL_DATA_HOSTS: ([^\n]+)") or ""):gmatch("%S+") do hosts[#hosts + 1] = host end
            table.sort(hosts)
            assert.are.same({ "kr.cdn.blizzard.com", "level3.ssl.blizzard.com", "us.cdn.blizzard.com", "us.version.battle.net" }, hosts)
        end)

        it("gives the tool a closed network whose only way out is the proxy (black)", function()
            assert.is_truthy(step, "no spell data step")
            local joined = step.text:gsub("\\\n%s*", " ")
            -- One network, made closed; nothing else is ever made or joined.
            local made = {}
            for line in text:gmatch("docker network [^\n]*") do made[#made + 1] = line end
            assert.are.same({ "docker network create --internal ff-cdn", "docker network connect ff-cdn ff-proxy",
                "docker network rm ff-cdn >/dev/null" }, made)
            -- The proxy starts on the default network, then joins the closed
            -- one; only then does the tool run, and both are removed after.
            local proxyAt = joined:find("docker run %-d %-%-name ff%-proxy ")
            local connectAt = joined:find("docker network connect ff-cdn ff-proxy", 1, true)
            local toolAt = joined:find("/cli/wow-cli casc sync-forever-spells", 1, true)
            local removeAt = joined:find("docker rm -f ff-proxy", 1, true)
            assert.is_truthy(proxyAt and connectAt and toolAt and removeAt and proxyAt < connectAt and connectAt < toolAt
                and toolAt < removeAt, "the proxy isn't started, joined, used and removed in that order")
            local tool
            for _, command in ipairs(dockerRuns(job)) do
                if kind(command) == "spells" then tool = command end
            end
            assert.is_truthy(tool, "no spell data download")
            -- The proxy is the tool's only setting for reaching anything, for
            -- HTTPS only: plain HTTP has no proxy and no route.
            assert.is_truthy(tool:find("-e HTTPS_PROXY=http://ff-proxy:8888 ", 1, true), "the tool isn't given the proxy")
            for _, banned in ipairs({ "HTTP_PROXY", "ALL_PROXY", "http_proxy", "all_proxy", "NO_PROXY", "no_proxy" }) do
                assert.is_falsy(tool:gsub("HTTPS_PROXY", ""):find(banned, 1, true), "the tool is given " .. banned)
            end
            -- Stopped at a time limit, with the tool read-only and one folder to write.
            assert.is_truthy(joined:find("timeout %-s TERM %-k 10 %d+ docker run %-%-rm %-%-init %-%-network ff%-cdn "),
                "the download has no time limit")
            assert.is_truthy(tool:find('-v "$RUNNER_TEMP/spell-cli:/cli:ro" -v "$RUNNER_TEMP/spell-out:/spells" ', 1, true),
                "the tool's mounts changed")
            assert.is_truthy(tool:find("-e WOW_SIM_CASC=0 ", 1, true), "the tool may look for game files")
            -- The tool is copied as a plain file before it's mounted.
            assert.is_truthy(step.text:find('\n%s*test %-f "%$cli"\n%s*test ! %-L "%$cli"\n'), "the tool isn't checked as a plain file")
            -- A failed download fails the step, after the proxy is removed.
            assert.is_truthy(step.text:find('\n%s*%[ "%$status" %-eq 0 %]%s*$'), "a failed download doesn't fail the step")
        end)

        -- The step's own shell, with a stand-in docker: what it writes for
        -- the proxy, and what it does when the tool fails.
        local function runStep(env, toolExit)
            local block = step.text:match("run: |\n(.*)$")
            local dir = os.tmpname()
            os.remove(dir)
            assert.is_true(os.execute("mkdir -p '" .. dir .. "/bin' '" .. dir .. "/sim-target/release'"
                .. " && echo tool > '" .. dir .. "/sim-target/release/wow-cli'") == 0)
            local fake = assert(io.open(dir .. "/bin/docker", "w"))
            fake:write("#!/bin/sh\necho \"docker $*\" >> '" .. dir .. "/docker.log'\n",
                "case \"$*\" in\n  *wow-cli*) echo '::error::from the tool'; exit " .. (toolExit or 0) .. " ;;\n",
                "  logs*) echo 'CONNECT Request (file descriptor 4): CONNECT us.version.battle.net:443 HTTP/1.1' ;;\nesac\n")
            fake:close()
            os.execute("chmod +x '" .. dir .. "/bin/docker'")
            local indent = block:match("^( *)")
            local body = {}
            for line in (block .. "\n"):gmatch("([^\n]*)\n") do body[#body + 1] = (line:gsub("^" .. indent, "", 1)) end
            local f = assert(io.open(dir .. "/run.sh", "wb"))
            f:write("set -eo pipefail\nRUNNER_TEMP='" .. dir .. "'\nPATH='" .. dir .. "/bin':\"$PATH\"\nsleep() { :; }\n")
            for name, value in pairs(env) do f:write(name .. "='" .. value .. "'\n") end
            f:write(table.concat(body, "\n"), "\n")
            f:close()
            local status = os.execute("bash '" .. dir .. "/run.sh' > '" .. dir .. "/step.log' 2>&1")
            local function read(name)
                local file = io.open(dir .. "/" .. name, "rb")
                local content = file and file:read("*a") or ""
                if file then file:close() end
                return content
            end
            local result = { ok = status == 0 or status == true, log = read("step.log"), docker = read("docker.log"),
                conf = read("spell-proxy/tinyproxy.conf"), filter = read("spell-proxy/filter") }
            os.execute("chmod -R u+w '" .. dir .. "'; rm -rf '" .. dir .. "'")
            return result
        end
        local ENV = { RENDER_BASE = "debian@sha256:0", SPELL_DATA_HOSTS = "us.version.battle.net level3.ssl.blizzard.com" }

        -- What these settings do was tried against tinyproxy 1.11.1 (Debian
        -- bookworm's), by this PR's driver and its architecture review:
        -- with FilterURLs the filter reads "host:port" for a CONNECT and the
        -- whole URL for a plain request, so "^host:443$" passes only an
        -- HTTPS tunnel to that host. Without FilterURLs it read the host
        -- alone, and plain HTTP to a listed host passed on any port.
        it("writes a proxy filter of exactly the listed hosts on port 443, read against the whole request (white)", function()
            local r = runStep(ENV)
            assert.is_true(r.ok, r.log)
            assert.are.equal("^us\\.version\\.battle\\.net:443$\n^level3\\.ssl\\.blizzard\\.com:443$\n", r.filter)
            for _, line in ipairs({ "ConnectPort 443", "FilterDefaultDeny Yes", "FilterType ere", "FilterURLs On",
                'Filter "/proxy/filter"' }) do
                assert.is_truthy(("\n" .. r.conf):find("\n" .. line .. "\n", 1, true), "the proxy's settings lack " .. line)
            end
            -- Every filter line is one host, anchored at both ends, with its port.
            for line in r.filter:gmatch("[^\n]+") do
                assert.is_truthy(line:find("^%^[a-z0-9%.\\%-]+:443%$$"), "a filter line isn't a host on port 443: " .. line)
            end
            assert.are.equal(1, select(2, r.conf:gsub("ConnectPort", "")), "the proxy allows another port")
            assert.is_falsy(r.conf:find("Upstream", 1, true) or r.conf:find("Allow", 1, true), "the proxy has settings nobody reviewed")
            -- The tool's output and the proxy's log reach the job log marked, never as commands (#153).
            assert.is_truthy(r.log:find("\n| ::error::from the tool\n", 1, true) or r.log:find("^| ::error::from the tool\n"), r.log)
            assert.is_falsy(r.log:find("\n::", 1, true), "a line of the tool's reads as a workflow command")
            assert.is_truthy(r.log:find("proxy> CONNECT Request", 1, true), "the proxy's log isn't shown")
            -- The proxy and its network are removed.
            assert.is_truthy(r.docker:find("docker rm -f ff-proxy\ndocker network rm ff-cdn\n", 1, true), r.docker)
        end)

        it("fails when the tool fails, after removing the proxy and its network (black)", function()
            local r = runStep(ENV, 3)
            assert.is_false(r.ok, "a failed download passes the step")
            assert.is_truthy(r.log:find("wow-cli: exit 3", 1, true), r.log)
            assert.is_truthy(r.docker:find("docker rm -f ff-proxy\ndocker network rm ff-cdn\n", 1, true), r.docker)
        end)

        it("refuses a host that isn't a plain name, before anything runs (black)", function()
            for _, hosts in ipairs({ "us.cdn.blizzard.com .*", "us.cdn.blizzard.com|evil.example", "US.cdn.blizzard.com",
                "us.cdn.blizzard.com:8080", "http://us.cdn.blizzard.com", "" }) do
                local r = runStep({ RENDER_BASE = "debian@sha256:0", SPELL_DATA_HOSTS = hosts })
                assert.is_false(r.ok, "the step ran with SPELL_DATA_HOSTS='" .. hosts .. "'")
                assert.is_falsy(r.docker:find("docker run", 1, true), "a container ran with SPELL_DATA_HOSTS='" .. hosts .. "'")
            end
        end)
    end)

    -- Containers only ever run the pinned image or the two images built here
    -- from the pinned bases, and nothing builds the simulator's own Dockerfile
    -- (that would run its build scripts on the runner's Docker, with network).
    it("runs only the pinned image and the images it builds from the pinned bases", function()
        local allowed = { run = true, build = true, inspect = true, stats = true, logs = true,
            kill = true, rm = true, top = true, ps = true, network = true }
        for command in text:gmatch("docker (%l+)") do
            assert.is_true(allowed[command] == true, "the workflow runs docker " .. command)
        end
        local built = {}
        for line in text:gmatch("docker build[^\n]*") do
            local name = line:match("^docker build %-t (ff%-%l+) %- <<DOCKERFILE%s*$")
            assert.is_truthy(name, "docker build doesn't build the workflow's own Dockerfile: " .. line)
            built[#built + 1] = name
        end
        -- ff-proxy is the spell data step's (#160); ff-render is built in
        -- each job that runs the simulator.
        assert.are.same({ "ff-build", "ff-proxy", "ff-render", "ff-render" }, built)
        for _, job in ipairs(order) do
            for _, command in ipairs(dockerRuns(job)) do
                local image = command:find("%sff%-build%s") or command:find("%sff%-render%s")
                    or (kind(command) == "proxy" and command:find("%sff%-proxy%s"))
                assert.is_truthy(image, job.name .. ": docker run of an image that isn't pinned: " .. command)
                assert.is_falsy(command:find("ghcr%.io") or command:find("@sha256"), job.name .. ": docker run names an image")
            end
        end
    end)

    -- #170: the finished build is cached, keyed on everything that shapes it.
    describe("simulator build cache (#170)", function()
        local build, keyStep, restore, save

        setup(function()
            build = jobs["simulator"]
            for _, step in ipairs(build.steps) do
                if step.text:find("id: key", 1, true) then keyStep = step end
                if step.text:find("actions/cache/restore@", 1, true) then restore = step end
                if step.text:find("actions/cache/save@", 1, true) then save = step end
            end
        end)

        it("keys the cache on every pin and build setting the build uses (black)", function()
            assert.is_truthy(keyStep and restore and save, "the key, restore and save steps are missing")
            -- Every variable the fetch, image and build steps read, besides
            -- the repository URLs, must be in the key's hash.
            local used = {}
            for _, step in ipairs(build.steps) do
                if step ~= keyStep then
                    for var in step.text:gmatch("%$[{]?([A-Z][A-Z_0-9]+)") do
                        if var:find("^SIM_") or var:find("^BUILD_") or var:find("^BLIZZARD_") or var:find("^SPELL_") then
                            used[var] = true
                        end
                    end
                end
            end
            for _, var in ipairs({ "SIM_COMMIT", "SIM_PROFILE", "BLIZZARD_UI_COMMIT", "BLIZZARD_UI_VERSION", "BUILD_BASE",
                "BUILD_TOOLCHAIN", "BUILD_PACKAGES", "BUILD_FEATURES", "BUILD_STRIP", "SPELL_DATA_HOSTS", "SPELL_DATA_SHA256" }) do
                assert.is_true(used[var], var .. " is no longer used by the build; update this check")
            end
            for var in pairs(used) do
                if var ~= "SIM_REPO" then
                    assert.is_truthy(keyStep.text:find("$" .. var, 1, true), "the cache key leaves out " .. var)
                end
            end
            assert.is_truthy(keyStep.text:find("sha256sum", 1, true), "the key isn't a hash of its inputs")
            -- The workflow file's own hash is in the key, so editing any
            -- build step, even a literal flag, misses the cache.
            assert.is_truthy(keyStep.text:find("hashFiles('.github/workflows/ui-sim.yml')", 1, true), "the key leaves out the workflow file's hash")
            assert.is_truthy(keyStep.text:find('"workflow=$WORKFLOW_HASH"', 1, true), "the workflow hash isn't in the key's inputs")
            -- So are the spell data check and the copy it checks against (#160).
            assert.is_truthy(keyStep.text:find("SPELL_CHECK_HASH: ${{ hashFiles('scripts/sim-spell-check.py', 'scripts/data/forever-spells.json') }}", 1, true),
                "the key leaves out the spell data check's files")
            assert.is_truthy(keyStep.text:find('"spell-check=$SPELL_CHECK_HASH"', 1, true), "the spell data check isn't in the key's inputs")
            assert.is_truthy(build.text:find("sparse-checkout: |\n            .github/workflows/ui-sim.yml\n            scripts/sim-spell-check.py\n"
                .. "            scripts/data/forever-spells.json\n", 1, true), "the files the key hashes aren't the ones checked out")
            assert.is_truthy(build.text:find("sparse-checkout-cone-mode: false", 1, true), "the sparse checkout reads the path as a folder")
            local checkoutAt, keyAt
            for i, step in ipairs(build.steps) do
                if step.text:find("actions/checkout@", 1, true) then checkoutAt = i end
                if step == keyStep then keyAt = i end
            end
            assert.is_truthy(checkoutAt and keyAt and checkoutAt < keyAt, "the workflow file is checked out after the key is worked out")
            -- Both cache steps use the one computed key, and cache the staged folder.
            for _, step in ipairs({ restore, save }) do
                assert.are.equal("${{ steps.key.outputs.key }}", step.text:match("\n%s*key:%s*([^\n]+)"), "a cache step doesn't use the computed key")
                assert.are.equal("${{ runner.temp }}/ui-sim-build", step.text:match("\n%s*path:%s*([^\n]+)"), "a cache step doesn't cache the staged build")
            end
        end)

        -- A step's run: block, as the shell gets it, run for real in a fresh
        -- folder: env is a table of variables, and prepare(dir) builds the
        -- fixture. Returns the exit status, the log and the folder's reader.
        local function runBlock(step, env, prepare)
            local block = step.text:match("run: |\n(.*)$")
            assert.is_truthy(block, "the step has no run block")
            local dir = os.tmpname()
            os.remove(dir)
            assert.is_true(os.execute("mkdir -p '" .. dir .. "'") == 0)
            if prepare then prepare(dir) end
            local f = assert(io.open(dir .. "/run.sh", "wb"))
            -- Dedent the block evenly.
            local indent = block:match("^( *)")
            local body = {}
            for line in (block .. "\n"):gmatch("([^\n]*)\n") do body[#body + 1] = (line:gsub("^" .. indent, "", 1)) end
            f:write("set -eo pipefail\nRUNNER_TEMP='" .. dir .. "'\nGITHUB_OUTPUT='" .. dir .. "/out'\n")
            for name, value in pairs(env or {}) do f:write(name .. "='" .. value .. "'\n") end
            f:write(table.concat(body, "\n"), "\n")
            f:close()
            local status = os.execute("bash '" .. dir .. "/run.sh' > '" .. dir .. "/step.log' 2>&1")
            local function read(name)
                local file = io.open(dir .. "/" .. name, "rb")
                local content = file and file:read("*a") or ""
                if file then file:close() end
                return content
            end
            local result = { status = status, log = read("step.log"), out = read("out") }
            os.execute("rm -rf '" .. dir .. "'")
            return result
        end

        it("really changes the key when any one input changes (black)", function()
            local base = { SIM_COMMIT = "a", BLIZZARD_UI_COMMIT = "b", BUILD_BASE = "c", BUILD_PACKAGES = "d",
                BUILD_FEATURES = "e", BUILD_STRIP = "f", WORKFLOW_HASH = "g", SIM_PROFILE = "h", BLIZZARD_UI_VERSION = "i",
                BUILD_TOOLCHAIN = "j", SPELL_DATA_HOSTS = "k l", SPELL_DATA_SHA256 = "m", SPELL_CHECK_HASH = "n" }
            local function key(env)
                local r = runBlock(keyStep, env)
                assert.is_true(r.status == 0 or r.status == true, "the key step failed: " .. r.log)
                local hash = r.out:match("^key=wow%-ui%-sim%-build%-(%x+)\n$")
                assert.is_truthy(hash and #hash == 64, "the key isn't a 64-character hash: " .. r.out)
                return hash
            end
            for _, hash in ipairs({ "WORKFLOW_HASH", "SPELL_CHECK_HASH" }) do
                local empty = {}
                for k, v in pairs(base) do empty[k] = v end
                empty[hash] = ""
                local refused = runBlock(keyStep, empty)
                assert.is_false(refused.status == 0 or refused.status == true, "an empty " .. hash .. " gives a key anyway")
            end
            local first = key(base)
            assert.are.equal(first, key(base), "the same inputs give another key")
            -- WORKFLOW_HASH is named in the step's env: block, from the file's hash.
            assert.is_truthy(keyStep.text:find("WORKFLOW_HASH: ${{ hashFiles('.github/workflows/ui-sim.yml') }}", 1, true),
                "WORKFLOW_HASH isn't the workflow file's hash")
            for name in pairs(base) do
                local changed = {}
                for k, v in pairs(base) do changed[k] = v end
                changed[name] = base[name] .. "x"
                assert.are_not.equal(first, key(changed), "changing " .. name .. " doesn't change the key")
            end
        end)

        it("refuses a restored or built tree with a link, a special file or a missing part (black)", function()
            local check
            for _, step in ipairs(build.steps) do
                if step.text:find("Check the staged files", 1, true) then check = step end
            end
            -- The spell data is our committed copy, so the check against it passes.
            local committed = wow.ROOT .. "/scripts/data/forever-spells.json"
            local function tree(dir)
                local o = dir .. "/ui-sim-build"
                assert.is_true(os.execute("mkdir -p '" .. o .. "/sim/Interface/AddOns/TestFramework' '" .. o
                    .. "/blizzard-ui/AddOns/Blizzard_X' '" .. o .. "/sim/spells/wowforever' && touch '" .. o .. "/sim/wow-sim' '" .. o
                    .. "/blizzard-ui/AddOns/Blizzard_X/a.lua' '" .. o .. "/blizzard-ui/AddOns/.marker' && cp '" .. committed
                    .. "' '" .. o .. "/sim/spells/wowforever/spells.json'") == 0)
            end
            local function run(extra, hash)
                return runBlock(check, { SIM_PROFILE = "wowforever", SPELL_DATA_SHA256 = hash or COMMITTED_SPELLS_SHA256 }, function(dir)
                    tree(dir)
                    if extra then assert.is_true(os.execute(extra:gsub("OUT", dir .. "/ui-sim-build")) == 0, "fixture failed: " .. extra) end
                end)
            end
            local function result(extra, hash)
                local r = run(extra, hash)
                return r.status == 0 or r.status == true
            end
            assert.is_true(result(), "a complete tree of plain files is refused: " .. run().log)
            local bad = {
                "rm OUT/sim/wow-sim && ln -s /bin/sh OUT/sim/wow-sim",
                "rm OUT/sim/wow-sim",
                "mkdir OUT/../plain-target && touch OUT/../plain-target/a && ln -s ../../../../plain-target OUT/blizzard-ui/AddOns/Blizzard_X/deep",
                "touch OUT/../plain-target-file && ln -s ../../../../plain-target-file OUT/blizzard-ui/AddOns/Blizzard_X/deepfile",
                "mkfifo OUT/sim/Interface/AddOns/TestFramework/pipe",
                "rmdir OUT/sim/Interface/AddOns/TestFramework",
                "rm -r OUT/blizzard-ui/AddOns",
                -- The spell data (#160): missing, a link to the right file, or the wrong folder.
                "rm OUT/sim/spells/wowforever/spells.json",
                "rm OUT/sim/spells/wowforever/spells.json && ln -s '" .. committed .. "' OUT/sim/spells/wowforever/spells.json",
                "mv OUT/sim/spells/wowforever OUT/sim/spells/retail",
            }
            for _, extra in ipairs(bad) do
                assert.is_false(result(extra), "the check passes for: " .. extra)
            end
            assert.is_falsy(check.text:find("||", 1, true), "the check can be made to pass with ||")
            assert.is_falsy(check.text:find("%f[%w]if:") or check.text:find("continue%-on%-error"), "the check can be skipped or made non-blocking")
        end)

        -- #160: the spell data must be the pinned download, byte for byte,
        -- whether it was just downloaded or came out of the cache.
        it("refuses spell data whose hash isn't the pinned one, and names the hash it has (black)", function()
            local check
            for _, step in ipairs(build.steps) do
                if step.text:find("Check the staged files", 1, true) then check = step end
            end
            local committed = wow.ROOT .. "/scripts/data/forever-spells.json"
            local function run(change, hash)
                return runBlock(check, { SIM_PROFILE = "wowforever", SPELL_DATA_SHA256 = hash }, function(dir)
                    local o = dir .. "/ui-sim-build"
                    assert.is_true(os.execute("mkdir -p '" .. o .. "/sim/Interface/AddOns/TestFramework' '" .. o
                        .. "/blizzard-ui/AddOns' '" .. o .. "/sim/spells/wowforever' && touch '" .. o .. "/sim/wow-sim' && cp '"
                        .. committed .. "' '" .. o .. "/sim/spells/wowforever/spells.json'"
                        .. (change and (" && " .. change:gsub("FILE", o .. "/sim/spells/wowforever/spells.json")) or "")) == 0)
                end)
            end
            local function ok(r) return r.status == 0 or r.status == true end
            assert.is_true(ok(run(nil, COMMITTED_SPELLS_SHA256)), "the pinned file is refused")
            -- One byte more: another hash, named in an annotation, in hex only.
            local r = run("printf ' ' >> FILE", COMMITTED_SPELLS_SHA256)
            assert.is_false(ok(r), "a changed file passes")
            local named = r.log:match("\n?::error title=UI simulator: Forever spell data is not the pinned download::Its SHA%-256 is (%x+), ")
            assert.is_truthy(named and #named == 64 and named ~= COMMITTED_SPELLS_SHA256, "the annotation doesn't name the file's hash: " .. r.log)
            assert.is_falsy(r.log:find("spell data check", 1, true), "a file with the wrong hash was read")
            -- The placeholder the pin starts from, and an empty pin, match nothing.
            assert.is_false(ok(run(nil, ("0"):rep(64))), "the placeholder hash passes")
            assert.is_false(ok(run(nil, "")), "an empty pin passes")
            -- Too big to be the spell data: refused before it's hashed or read.
            local big = run("head -c 1048577 /dev/zero > FILE", COMMITTED_SPELLS_SHA256)
            assert.is_false(ok(big), "a file over 1 MiB passes")
            assert.is_falsy(big.log:find("SHA-256 is", 1, true), "a file over 1 MiB was hashed")
            -- The right hash for a file that differs from our committed copy:
            -- the row check stops it.
            local changed = "sed -i 's/Waterbreathing\\./Waterbreathing!/' FILE"
            local hashOf = runBlock({ text = "run: |\n  " .. changed:gsub("FILE", '"$RUNNER_TEMP/f"') .. '\n  sha256sum "$RUNNER_TEMP/f"\n' }, {},
                function(dir) assert.is_true(os.execute("cp '" .. committed .. "' '" .. dir .. "/f'") == 0) end)
            local other = hashOf.log:match("^(%x+) ")
            assert.is_truthy(other and #other == 64 and other ~= COMMITTED_SPELLS_SHA256, "the fixture didn't change the file: " .. hashOf.log)
            local wrongRows = run(changed, other)
            assert.is_false(ok(wrongRows), "spell data that differs from our committed copy passes")
            assert.is_truthy(wrongRows.log:find("spell data check failed", 1, true), wrongRows.log)
        end)

        it("pins a real hash for the spell data, and checks it before the row check reads the file (black)", function()
            -- In quotes: YAML reads an unquoted value of digits as a number (the
            -- placeholder of zeros reached the first run as 0).
            local pinned = text:match('\n%s*SPELL_DATA_SHA256: "(%x+)"\n')
            assert.is_truthy(pinned and #pinned == 64 and not pinned:find("[^0-9a-f]"), "SPELL_DATA_SHA256 isn't a quoted SHA-256")
            assert.are_not.equal(("0"):rep(64), pinned, "SPELL_DATA_SHA256 is still the placeholder")
            local check
            for _, step in ipairs(build.steps) do
                if step.text:find("Check the staged files", 1, true) then check = step end
            end
            local hashAt = check.text:find('if [ "$actual" != "$SPELL_DATA_SHA256" ]; then', 1, true)
            local readAt = check.text:find('python3 -I scripts/sim-spell-check.py "$spells" scripts/data/forever-spells.json', 1, true)
            assert.is_truthy(hashAt and readAt and hashAt < readAt, "the spell data is read before its hash is checked")
            assert.is_truthy(check.text:find('spells="$out/sim/spells/$SIM_PROFILE/spells.json"', 1, true), "the checked file isn't the staged one")
            -- Nothing else in the workflow reads it on the runner.
            assert.are.equal(1, select(2, text:gsub("sim%-spell%-check%.py \"", "")), "the row check runs somewhere else too")
        end)

        it("restores only the exact key, never a prefix (black)", function()
            assert.is_falsy(restore.text:find("restore-keys", 1, true), "a prefix restore could bring back an older build")
        end)

        it("skips the fetch and build on a hit, and saves only after a miss (white)", function()
            local steps = {}
            for i, step in ipairs(build.steps) do
                local skipped = step.text:find("if: steps.sim-cache.outputs.cache-hit != 'true'", 1, true) ~= nil
                steps[#steps + 1] = { name = step.text, skipped = skipped, index = i }
            end
            local function find(fragment)
                for _, entry in ipairs(steps) do
                    if entry.name:find(fragment, 1, true) then return entry end
                end
                error("no step " .. fragment)
            end
            assert.is_truthy(restore.text:find("\n%s*id:%s*sim%-cache\n"), "the skip conditions read an id the restore step doesn't have")
            for _, fragment in ipairs({ "Fetch the simulator", "Build a build image", "Download the simulator", "Build the simulator",
                "Download Forever's spell data", "Stage the simulator", "Save the staged" }) do
                assert.is_true(find(fragment).skipped, fragment .. " runs on a cache hit")
            end
            -- The spell data is downloaded with the tool the build made, and staged after.
            assert.is_true(find("Build the simulator").index < find("Download Forever's spell data").index
                and find("Download Forever's spell data").index < find("Stage the simulator").index,
                "the spell data isn't downloaded between the build and the staging")
            for _, fragment in ipairs({ "Work out the cache key", "Restore the staged", "Check the staged files", "actions/upload-artifact" }) do
                assert.is_false(find(fragment).skipped, fragment .. " is skipped on a hit")
            end
            assert.is_true(find("Work out").index < find("Restore the staged").index, "the key comes after the restore")
            assert.is_true(find("Restore the staged").index < find("Fetch the simulator").index, "the restore comes after the fetch")
            assert.is_true(find("Stage the simulator").index < find("Check the staged files").index
                and find("Check the staged files").index < find("Save the staged").index
                and find("Save the staged").index < find("actions/upload").index, "nothing unchecked may be saved: stage, check, save, upload")
        end)

        it("checks a restored build holds only plain files before it is uploaded (black)", function()
            local check
            for _, step in ipairs(build.steps) do
                if step.text:find("Check the staged files", 1, true) then check = step end
            end
            assert.is_truthy(check, "no check of the staged files")
            assert.is_falsy(check.text:find("cache%-hit"), "the check is skipped on a hit")
            assert.is_truthy(check.text:find('test -f "$out/sim/wow-sim"', 1, true), "the binary isn't checked as a file")
            assert.is_truthy(check.text:find('test ! -L "$out/sim/wow-sim"', 1, true), "the binary isn't checked as not a link")
            assert.is_truthy(check.text:find("! -type f ! -type d", 1, true), "links and special files in the tree aren't refused")
            assert.is_falsy(text:find("cargo%-home\n%s+%${{ runner%.temp }}/sim%-target"), "the old cargo cache is still cached")
        end)
    end)

    -- #160: upstream's master of 2026-11-13, reviewed on #160 before the pin
    -- moved (#154 moved it before). There's no published image at that
    -- commit, and release binaries are never used, so the simulator job
    -- builds it and the others run that.
    it("pins wow-ui-sim at the reviewed 936d5f5 and runs only the build made from it (black)", function()
        assert.is_truthy(text:find("\n%s*SIM_COMMIT: 936d5f53841ee620384b7f05a0f8d5e861835c3d\n"),
            "the simulator isn't pinned at the reviewed commit")
        assert.is_truthy(text:find("\n%s*BUILD_BASE: rust@sha256:e6f2cff35d0f309acf8433b4f05878ed77092602c5065cc81801177da0bb3a9c%s"),
            "the build base isn't the reviewed digest")
        assert.is_truthy(text:find("\n%s*RENDER_BASE: debian@sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3%s"),
            "the render base isn't the reviewed digest")
        -- Forever (#160, the owner's decision): the profile, its features and
        -- Blizzard's UI at the commit the simulator's source names.
        assert.is_truthy(text:find("\n%s*SIM_PROFILE: wowforever\n"), "the simulator doesn't play Forever")
        assert.is_truthy(text:find("\n%s*BUILD_FEATURES: gui client%-wowforever tools\n"), "the build isn't the Forever one")
        assert.is_truthy(text:find("\n%s*BLIZZARD_UI_COMMIT: aff0d8cd53bf4d9ef1c1dd2786b94461a276fb16\n"),
            "Blizzard's UI isn't at the reviewed commit")
        assert.is_truthy(text:find("\n%s*BLIZZARD_UI_VERSION: 1%.60%.1%.70707\n"), "Blizzard's UI isn't the reviewed version")
        -- The image's own toolchain, the one the source asks for, so rustup
        -- never downloads another: in the download and in the build.
        assert.is_truthy(text:find("\n%s*BUILD_TOOLCHAIN: 1%.99%.1\n"), "the toolchain isn't the one the source asks for")
        local toolchains = 0
        for _, command in ipairs(dockerRuns(jobs.simulator)) do
            if command:find("%sff%-build cargo ") then
                toolchains = toolchains + 1
                assert.is_truthy(command:find('-e RUSTUP_TOOLCHAIN="$BUILD_TOOLCHAIN" ', 1, true), "cargo may fetch a toolchain: " .. command)
            end
        end
        assert.are.equal(2, toolchains, "expected cargo fetch and cargo build")
        for _, banned in ipairs({ "ghcr%.io", "docker pull", "IMAGE:", "releases/download", "%.dmg", "%.tar%.gz" }) do
            assert.is_falsy(text:find(banned), "a published image or release binary is used: " .. banned)
        end
        -- One build, in its own job, which the jobs that run it wait for.
        local build = jobs["simulator"]
        assert.is_truthy(build and build.text:find("cargo build", 1, true), "no simulator job builds it")
        -- Its output is untrusted: stripped inside the sandboxed build, and
        -- on the runner only copied, as a plain file (#154's review).
        local buildRun = dockerRuns(build)
        local stripped = false
        for _, command in ipairs(buildRun) do
            if command:find("cargo build", 1, true) then
                stripped = command:find('-e CARGO_PROFILE_RELEASE_STRIP="$BUILD_STRIP"', 1, true) ~= nil
                    and text:find("\n%s*BUILD_STRIP: symbols\n") ~= nil
            end
        end
        assert.is_true(stripped, "the build doesn't strip the binary in its sandbox")
        local outside = build.text:gsub("\\\n%s*", " "):gsub("docker run[^\n]*", "")
        for _, tool in ipairs({ "strip", "objcopy", "readelf", "objdump", "file", "ldd", "nm" }) do
            assert.is_falsy(outside:find("%f[%w]" .. tool .. "%s"), "the runner reads the build's output with " .. tool)
        end
        assert.is_truthy(build.text:find('\n%s*test %-f "%$bin"\n%s*test ! %-L "%$bin"\n%s*cp %-P "%$bin" '),
            "the binary is copied without checking it's a plain file")
        -- So is the spell data, into the folder the simulator reads beside its binary.
        assert.is_truthy(build.text:find('\n%s*test %-f "%$spells"\n%s*test ! %-L "%$spells"\n%s*mkdir %-p "%$out/sim/spells/%$SIM_PROFILE"\n'
            .. '%s*cp %-P "%$spells" "%$out/sim/spells/%$SIM_PROFILE/spells%.json"\n'), "the spell data is copied without checking it's a plain file")
        -- wow-cli is built for the spell data step only: it never reaches the other jobs.
        local stage
        for _, step in ipairs(build.steps) do
            if step.text:find("name: Stage the simulator", 1, true) then stage = step end
        end
        assert.is_falsy(stage.text:find("wow-cli", 1, true), "wow-cli is staged for the other jobs")
        for _, name in ipairs({ "ui-sim", "screenshots" }) do
            local job = jobs[name]
            assert.is_truthy(job, "no " .. name .. " job")
            assert.is_truthy(job.text:find("\n%s*needs: simulator\n"), name .. " doesn't wait for the build")
            assert.is_falsy(job.text:find("cargo", 1, true), name .. " builds the simulator itself")
            for _, command in ipairs(dockerRuns(job)) do
                assert.is_truthy(command:find("%-v \"%$RUNNER_TEMP/ui%-sim%-build/sim:/sim:ro\""),
                    name .. ": runs a simulator that isn't the build's, or mounts it writable: " .. command)
                assert.is_truthy(command:find("ff%-render /sim/wow%-sim "), name .. ": runs something else: " .. command)
                -- Forever's UI code where the Forever profile looks for it, unless the run loads no UI (the probe).
                if command:find("blizzard-ui", 1, true) then
                    assert.is_truthy(command:find('-v "$RUNNER_TEMP/ui-sim-build/blizzard-ui/AddOns:/tmp/.cache/wow-ui-sim/blizzard-ui/$SIM_PROFILE/AddOns:ro"', 1, true),
                        name .. ": Blizzard's UI isn't where the profile looks: " .. command)
                else
                    assert.is_truthy(command:find("/sim/wow-sim --help", 1, true), name .. ": a run without Blizzard's UI: " .. command)
                end
                -- The profile's interface version is our TOC's, so the addon
                -- must load without the game's "Load out of date AddOns".
                assert.is_falsy(command:find("OUT_OF_DATE", 1, true), name .. ": loads the addon as out of date")
            end
        end
    end)

    -- A shot's container can write /shots, so it can plant a link there. A
    -- redirect or copy by the runner into that folder would follow the link
    -- and overwrite a file of the shot's choosing (#147).
    it("never has the runner write into a folder a container mounts writable", function()
        local joined = text:gsub("\\\n%s*", " ")
        local writable = {}
        for _, job in ipairs(order) do
            for _, command in ipairs(dockerRuns(job)) do
                for mount in command:gmatch("%-v%s+(%S+)") do
                    if not mount:find(":ro\"?$") then
                        writable[#writable + 1] = mount:match('^"?([^:]+):')
                    end
                end
            end
        end
        assert.is_true(#writable >= 3, "expected writable mounts to check")
        -- Quotes and braces don't change which folder a path names.
        local function plain(value) return (value:gsub('["{}]', "")) end
        local function inMounted(target)
            for _, dir in ipairs(writable) do
                if plain(target):find(plain(dir), 1, true) then return dir end
            end
        end
        local checked = 0
        for line in (joined .. "\n"):gmatch("[^\n]+") do
            if not line:find("docker run", 1, true) then
                local targets = {}
                -- Redirects (not 2>&1 or >&2), appends, tee, and the last argument of cp, mv, ln, install.
                for target in line:gmatch("[^>&%d]>>?%s*(%S+)") do targets[#targets + 1] = target end
                for target in line:gmatch("tee%s+%-?a?%s*(%S+)") do targets[#targets + 1] = target end
                for _, tool in ipairs({ "cp", "mv", "ln", "install", "rsync", "unzip", "tar", "dd" }) do
                    if line:find("%f[%w]" .. tool .. "%f[%W]") then targets[#targets + 1] = line end
                end
                for _, target in ipairs(targets) do
                    checked = checked + 1
                    local dir = inMounted(target)
                    assert.is_falsy(dir, "the runner writes into " .. tostring(dir) .. ": " .. line)
                end
            end
        end
        assert.is_true(checked >= 5, "expected redirects and copies to check")
    end)

    it("keeps the shots' logs in the artifacts and the job's log groups", function()
        local job = jobs.screenshots
        assert.is_truthy(job.text:find('docker logs "$cid" > "$RUNNER_TEMP/shot-logs/$name$SUFFIX.log"', 1, true),
            "a shot's log isn't saved in shot-logs")
        assert.is_truthy(job.text:find('for log in "$RUNNER_TEMP"/shot-logs/*.log', 1, true), "the logs aren't shown in groups")
        assert.is_truthy(job.text:find("echo \"::group::", 1, true), "the logs aren't in log groups")
        assert.is_truthy(job.text:find("path: ${{ runner.temp }}/shot-logs", 1, true), "shot-logs isn't uploaded")
        assert.is_truthy(job.text:find("path: ${{ runner.temp }}/shots\n", 1, true), "the PNG artifact moved")
    end)

    it("uploads only plain PNG files from the folder shots write", function()
        local steps = jobs.screenshots.steps
        local clean = indexOf(steps, "find %-P")
        local upload = indexOf(steps, "name: ui%-sim%-screenshots\n")
        assert.is_truthy(clean and upload and clean < upload, "the shots folder isn't cleaned before the upload")
        local stepText = steps[clean].text
        local shots = indexOf(steps, "name: Take screenshots")
        assert.is_truthy(shots and shots < clean, "the clean-up doesn't come after the shots")
        local removal = stepText:find("docker ps -aq | xargs -r docker rm -f", 1, true)
        local find = stepText:find("find %-P")
        assert.is_truthy(removal and find and removal < find, "containers aren't removed before the clean-up")
        assert.is_truthy(stepText:find("if: always()", 1, true), "the clean-up is skipped when a step fails")
        assert.is_truthy(stepText:find([[! \( -type f -name '*.png' \) -delete]], 1, true), "the clean-up keeps more than plain PNGs")
        assert.is_truthy(stepText:find('find -P "$RUNNER_TEMP/shots" -mindepth 1', 1, true), "the clean-up follows links or misses the folder")
    end)

    -- #154: a hung simulator command held the scenario job until its limit
    -- and showed nothing. Each run now stops itself and says how it ended.
    it("stops every scenario-job simulator run at its own time limit, inside the job's (black)", function()
        local job = jobs["ui-sim"]
        local runs, total = 0, 0
        for _, command in ipairs(dockerRuns(job)) do
            runs = runs + 1
            assert.is_truthy(command:find("%-%-init", 1), "a simulator run without --init ignores the stop: " .. command)
        end
        local joined = job.text:gsub("\\\n%s*", " ")
        for _ in joined:gmatch("timeout %-s TERM %-k 10 %d+ docker run[^\n]*") do
            total = total + 1
        end
        assert.are.equal(2, runs, "expected the sandbox function's run and the sized pass's run")
        assert.are.equal(runs, total, "a simulator run has no time limit")
        local sandboxLimit = tonumber(joined:match("timeout %-s TERM %-k 10 (%d+) docker run[^\n]*\"%$@\""))
        local sizedLimit = tonumber(joined:match("timeout %-s TERM %-k 10 (%d+) docker run[^\n]*layout%.lua"))
        assert.is_truthy(sandboxLimit and sizedLimit, "the limits can't be read")
        local calls = select(2, joined:gsub("\n%s*attempt %S+ [^\n]* sandbox %l", ""))
        local sizes = select(2, (text:match("LAYOUT_SIZES: ([^\n]+)") or ""):gsub("%S+", ""))
        local jobLimit = tonumber(job.text:match("\n%s*timeout%-minutes: (%d+)"))
        assert.is_truthy(joined:find('\n%s*attempt "layout%-%$size" [^\n]* sized "%$size"\n'), "the sized passes aren't retried")
        -- Each run can run twice: once more when it's stopped (#173).
        local worst = 2 * (calls * (sandboxLimit + 10) + sizes * (sizedLimit + 10))
        assert.are.equal(3, calls, "expected lua-errors, run-tests and dump-tree")
        assert.is_true(worst + 180 <= jobLimit * 60, "the runs' limits don't fit in the job's")
        assert.is_truthy(job.text:find('echo "$1: exit $status after', 1, true), "the log doesn't say how each run ended")
    end)

    -- The run step's own shell, as the job runs it (bash -e -o pipefail), with
    -- a stand-in docker that finishes, fails, hangs, or hangs only the first
    -- time it's given each command, and the limits cut to 2 s. A hang must
    -- show as 124 in the step's log, naming the run, and the report files
    -- must keep only the simulator's output (#154's testing review). A run
    -- that hangs runs once more, keeping what the stopped one wrote, and
    -- runs.txt says how each attempt ended (#173).
    describe("the scenario job's run step, run for real (black)", function()
        local function runStep(mode)
            local workflow = wow.readFile(path)
            local step = workflow:match("name: Run the simulator[^\n]*\n%s*run: |\n(.-)\n\n%s*%- name:")
            assert.is_truthy(step, "no run step")
            assert.is_truthy(step:find("sized() {", 1, true), "no sized passes in the run step")
            step = step:gsub("timeout %-s TERM %-k 10 %d+", "timeout -s TERM -k 1 2")
            local dir = os.tmpname()
            os.remove(dir)
            assert.is_true(os.execute("mkdir -p '" .. dir .. "/bin' '" .. dir .. "/report' '" .. dir .. "/seen'") == 0)
            local fake = assert(io.open(dir .. "/bin/docker", "w"))
            fake:write("#!/bin/sh\nseen='" .. dir .. "/seen/'$(echo \"$*\" | cksum | cut -d' ' -f1)\n",
                "case \"$*\" in *lua-errors*) echo partial-err >&2 ;; esac\n",
                "case \"$FAKE\" in\n  hang) echo partial; exec sleep 30 ;;\n",
                "  once) if [ -e \"$seen\" ]; then echo body; else touch \"$seen\"; echo partial; exec sleep 30; fi ;;\n",
                "  fail) echo body; exit 3 ;;\n  *) echo body ;;\nesac\n")
            fake:close()
            local script = assert(io.open(dir .. "/run.sh", "w"))
            script:write("set -eo pipefail\nRUNNER_TEMP='" .. dir .. "'\nPATH='" .. dir .. "/bin':\"$PATH\"\nLAYOUT_SIZES=1024x768\n",
                step, "\necho finished\n")
            script:close()
            os.execute("chmod +x '" .. dir .. "/bin/docker'")
            local status = os.execute("FAKE=" .. mode .. " bash '" .. dir .. "/run.sh' > '" .. dir .. "/step.log' 2>&1")
            local function read(name)
                local f = io.open(dir .. "/" .. name)
                local content = f and f:read("*a")
                if f then f:close() end
                return content
            end
            local result = { status = status, step = read("step.log"), report = read("report/run-tests.log"),
                layout = read("report/layout-1024x768.log"), runs = read("runs.txt"),
                stopped = read("report/run-tests.log.timed-out"), stoppedJson = read("report/lua-errors.json.timed-out"),
                stoppedLayout = read("report/layout-1024x768.log.timed-out"),
                stoppedErrors = read("report/lua-errors.log.timed-out") }
            os.execute("rm -rf '" .. dir .. "'")
            return result
        end

        -- Each attempt's seconds, in runs.txt's order.
        local function times(runs)
            local list = {}
            for seconds in (runs or ""):gmatch("%S+ %d %d+ (%d+)\n") do list[#list + 1] = tonumber(seconds) end
            return list
        end

        -- runs.txt's lines, as { name, attempt, exit } strings.
        local function attempts(runs)
            local list = {}
            for name, try, status in (runs or ""):gmatch("(%S+) (%d) (%d+) %d+\n") do
                list[#list + 1] = name .. " " .. try .. " " .. status
            end
            return list
        end

        it("says each run finished, in the step's log, and keeps the report to the simulator's output", function()
            local r = runStep("ok")
            assert.are.equal(0, r.status)
            assert.is_truthy(r.step:find("\nrun%-tests: exit 0 after %d+ s"), r.step)
            assert.is_truthy(r.step:find("^lua%-errors: exit 0 after %d+ s"), r.step)
            assert.is_falsy(r.step:find("layout pass", 1, true), "a sized pass that finished is reported as failing")
            assert.are.equal("body\n", r.report)
            assert.are.equal("body\n", r.layout)
            assert.is_truthy(r.step:find("finished", 1, true))
            -- (white, #173) Each run once, and nothing kept as stopped.
            assert.are.same({ "lua-errors 1 0", "run-tests 1 0", "dump-tree 1 0", "layout-1024x768 1 0" }, attempts(r.runs))
            assert.is_nil(r.stopped)
            assert.is_nil(r.stoppedLayout)
        end)

        it("reports a failing run's own exit code, and carries on without running it again", function()
            local r = runStep("fail")
            assert.are.equal(0, r.status)
            assert.is_truthy(r.step:find("run%-tests: exit 3 after"), r.step)
            assert.is_truthy(r.step:find("layout pass 1024x768: exit 3", 1, true), r.step)
            assert.are.equal("body\n", r.report)
            assert.is_truthy(r.step:find("finished", 1, true))
            assert.are.same({ "lua-errors 1 3", "run-tests 1 3", "dump-tree 1 3", "layout-1024x768 1 3" }, attempts(r.runs))
        end)

        it("stops a hung run at its limit, says 124 with the time it ran, runs it once more, and carries on", function()
            local r = runStep("hang")
            assert.are.equal(0, r.status)
            local seconds = tonumber(r.step:match("run%-tests: exit 124 after (%d+) s"))
            assert.is_truthy(seconds, r.step)
            assert.is_true(seconds >= 2 and seconds <= 3, "run-tests' time counts from before it started: " .. seconds)
            assert.is_truthy(r.step:find("lua%-errors: exit 124 after"), r.step)
            assert.is_truthy(r.step:find("layout pass 1024x768: exit 124", 1, true), r.step)
            assert.are.equal("partial\n", r.report, "the exit line went into the report")
            assert.is_truthy(r.step:find("finished", 1, true))
            -- (black, #173) Twice each, never a third time, with the first
            -- attempt's output kept beside the second's.
            assert.are.same({ "lua-errors 1 124", "lua-errors 2 124", "run-tests 1 124", "run-tests 2 124",
                "dump-tree 1 124", "dump-tree 2 124", "layout-1024x768 1 124", "layout-1024x768 2 124" }, attempts(r.runs))
            assert.are.equal("partial\n", r.stopped)
            assert.are.equal("partial\n", r.stoppedJson)
            assert.are.equal("partial-err\n", r.stoppedErrors, "the stopped run's stderr isn't kept")
            -- Each attempt's own time, from its own start, at the 2 s limit.
            for i, took in ipairs(times(r.runs)) do
                assert.is_true(took >= 2 and took <= 3, "attempt " .. i .. " took " .. took .. " s")
            end
            assert.are.equal("partial\n", r.stoppedLayout)
        end)

        it("keeps a run that hung once and then finished as the report, and the stopped one beside it (white)", function()
            local r = runStep("once")
            assert.are.equal(0, r.status)
            assert.are.same({ "lua-errors 1 124", "lua-errors 2 0", "run-tests 1 124", "run-tests 2 0",
                "dump-tree 1 124", "dump-tree 2 0", "layout-1024x768 1 124", "layout-1024x768 2 0" }, attempts(r.runs))
            assert.are.equal("body\n", r.report)
            assert.are.equal("body\n", r.layout)
            assert.are.equal("partial\n", r.stopped)
            assert.are.equal("partial\n", r.stoppedLayout)
            assert.is_truthy(r.step:find("finished", 1, true))
            -- The stopped attempts ran to the 2 s limit; each retry is timed from its own start.
            local seconds = times(r.runs)
            assert.are.equal(8, #seconds)
            for i = 1, 8, 2 do
                assert.is_true(seconds[i] >= 2 and seconds[i] <= 3, "a stopped attempt took " .. seconds[i] .. " s")
                assert.is_true(seconds[i + 1] < 2, "a retry's time counts the stopped attempt: " .. seconds[i + 1])
            end
        end)
    end)

    -- The summary step's own shell, as the job runs it, on a report in which
    -- runs were stopped at their time limit (#173). Each one stopped is named
    -- at the top of the summary, with its last scenario and the end of its
    -- log, and in an annotation, and the job never fails. The logs are
    -- hostile: none of their text reaches the job log, where the runner reads
    -- commands, and none can close the summary's code blocks.
    describe("the scenario job's summary of runs stopped at their time limit, run for real", function()
        local HOSTILE = "START 6 an unknown command is answered, not an error\nLAYOUT ok 1024x768 panel\n"
            .. "START 7 ::error::seven\n```\n::warning::hostile\nx ##[set-env name=A;]b\r::error::carriage\n"
            .. "START 12::error::bad\nthe last line\n"

        local function summarize(runs, logs)
            local workflow = wow.readFile(path)
            local step = workflow:match("name: Summary\n%s*run: |\n(.-)\n\n")
            assert.is_truthy(step, "no summary step")
            local dir = os.tmpname()
            os.remove(dir)
            assert.is_true(os.execute("mkdir -p '" .. dir .. "/report'") == 0)
            local function write(name, content)
                local f = assert(io.open(dir .. "/" .. name, "wb"))
                f:write(content)
                f:close()
            end
            for _, name in ipairs({ "lua-errors.json", "lua-errors.log", "run-tests.log", "frame-tree.txt",
                "layout-1024x768.log" }) do
                write("report/" .. name, "body\n")
            end
            for name, content in pairs(logs or {}) do write("report/" .. name, content) end
            if runs then write("runs.txt", runs) end
            write("run.sh", "set -eo pipefail\nRUNNER_TEMP='" .. dir .. "'\nLAYOUT_SIZES=1024x768\n"
                .. "GITHUB_STEP_SUMMARY='" .. dir .. "/summary.md'\n" .. step .. "\n")
            local status = os.execute("bash '" .. dir .. "/run.sh' > '" .. dir .. "/step.log' 2>&1")
            local function read(name)
                local f = io.open(dir .. "/" .. name, "rb")
                local content = f and f:read("*a") or ""
                if f then f:close() end
                return content
            end
            local result = { status = status, log = read("step.log"), summary = read("summary.md") }
            os.execute("rm -rf '" .. dir .. "'")
            return result
        end

        local ALL_FINISHED = "lua-errors 1 0 3\nrun-tests 1 0 20\ndump-tree 1 0 3\nlayout-1024x768 1 0 25\n"

        -- The summary's text before its first section on the Lua errors.
        local function top(summary) return summary:match("^(.-)### Lua errors") end

        -- Lines as the runner splits them: at \n, \r or \r\n.
        local function runnerLines(out)
            local list = {}
            for line in (out:gsub("\r\n?", "\n") .. "\n"):gmatch("([^\n]*)\n") do list[#list + 1] = line end
            return list
        end

        it("reports a run that finished as before, with nothing at the top and no annotation (white)", function()
            local r = summarize(ALL_FINISHED)
            assert.are.equal(0, r.status)
            assert.are.equal("## UI simulator (report only)\n\n", top(r.summary))
            assert.are.equal("", r.log)
        end)

        it("notes a run that timed out, then finished on the retry, with its last scenario (white)", function()
            local r = summarize("lua-errors 1 0 3\nrun-tests 1 124 130\nrun-tests 2 0 21\ndump-tree 1 0 3\nlayout-1024x768 1 0 25\n",
                { ["run-tests.log.timed-out"] = HOSTILE })
            assert.are.equal(0, r.status)
            local head = top(r.summary)
            assert.is_truthy(head:find("### ⚠️ The main pass (run-tests, at 1600x1200) timed out once, and ran again (exit 0)", 1, true), head)
            assert.is_truthy(head:find("Stopped after 130 s, on attempt 1 of 2.", 1, true), head)
            assert.is_truthy(head:find("```\n| START 12::error::bad\n```", 1, true), head)
            assert.is_falsy(head:find("incomplete", 1, true), "a retry that finished is reported as lost")
            assert.are.equal("::notice title=UI simulator: a run timed out once::The main pass (run-tests, at 1600x1200) was "
                .. "stopped at its time limit and ran again (exit 0). Last scenario started: 12.\n", r.log)
        end)

        it("names a run that timed out twice at the top, with its size and last scenario, and never fails the job (black)", function()
            local r = summarize("lua-errors 1 0 3\nrun-tests 1 0 20\ndump-tree 1 0 3\nlayout-1024x768 1 124 310\n"
                .. "layout-1024x768 2 124 310\n",
                { ["layout-1024x768.log.timed-out"] = "START 3 first try\n", ["layout-1024x768.log"] = HOSTILE })
            assert.are.equal(0, r.status)
            local head = top(r.summary)
            local first = head:find("### ⚠️ The layout pass at 1024x768 timed out once, and ran again (exit 124)", 1, true)
            local second = head:find("### ⚠️ The layout pass at 1024x768 timed out twice: its results are incomplete", 1, true)
            assert.is_truthy(first and second and first < second, head)
            assert.is_truthy(head:find("```\n| START 3 first try\n```", 1, true), head)
            assert.is_truthy(head:find("```\n| START 12::error::bad\n```", 1, true), head)
            assert.is_truthy(head:find("| the last line\n```", 1, true), "the end of the log isn't shown")
            assert.is_truthy(head:find("| x ##(set-env name=A;]b\n| ::error::carriage\n| START 12::error::bad\n| the last line\n```", 1, true),
                "the end of the log isn't its last lines, marked")
            assert.is_truthy(head:find("\n| ```\n", 1, true), "a fence line in the log isn't shown, marked")
            local log = runnerLines(r.log)
            assert.are.same({
                "::notice title=UI simulator: a run timed out once::The layout pass at 1024x768 was stopped at its time "
                    .. "limit and ran again (exit 124). Last scenario started: 3.",
                "::warning title=UI simulator: a run timed out twice::The layout pass at 1024x768 was stopped at its time "
                    .. "limit twice, so its results (LAYOUT lines included) are incomplete. Last scenario started: 12. "
                    .. "See the run's summary.",
                "" }, log)
        end)

        it("reports as before when the run step wrote no runs.txt (black)", function()
            local r = summarize(nil)
            assert.are.equal(0, r.status)
            assert.are.equal("## UI simulator (report only)\n\n", top(r.summary))
            assert.are.equal("", r.log)
        end)

        it("shows the end of the frame tree's log when dump-tree timed out (black)", function()
            local r = summarize("lua-errors 1 0 3\nrun-tests 1 0 20\ndump-tree 1 124 130\ndump-tree 2 124 130\n"
                .. "layout-1024x768 1 0 25\n", { ["frame-tree.txt.timed-out"] = "first tree\n", ["frame-tree.txt"] = "the tree end\n" })
            local head = top(r.summary)
            assert.is_truthy(head:find("The dump-tree run timed out twice", 1, true), head)
            assert.is_truthy(head:find("| first tree\n", 1, true), head)
            assert.is_truthy(head:find("| the tree end\n", 1, true), head)
        end)

        it("says none when the stopped run started no scenario (black)", function()
            local r = summarize("lua-errors 1 124 130\nlua-errors 2 124 130\nrun-tests 1 0 20\ndump-tree 1 0 3\n"
                .. "layout-1024x768 1 0 25\n", { ["lua-errors.log"] = "::error::nothing\n" })
            assert.are.equal(0, r.status)
            assert.is_truthy(top(r.summary):find("The lua-errors run timed out twice", 1, true))
            assert.is_truthy(top(r.summary):find("```\n| ::error::nothing\n```", 1, true), "the lua-errors log isn't shown")
            assert.is_truthy(r.log:find("Last scenario started: none.", 1, true), r.log)
            assert.is_falsy(r.log:find("nothing", 1, true), "the log's text reached the annotation")
        end)

        it("keeps every line of a stopped run's log inside the summary's code blocks, and out of the job log (black)", function()
            local r = summarize("lua-errors 1 0 3\nrun-tests 1 124 130\nrun-tests 2 124 130\ndump-tree 1 0 3\n"
                .. "layout-1024x768 1 0 25\n", { ["run-tests.log.timed-out"] = HOSTILE, ["run-tests.log"] = HOSTILE })
            assert.are.equal(0, r.status)
            local inside = false
            for _, line in ipairs(runnerLines(top(r.summary))) do
                if line == "```" then
                    inside = not inside
                elseif inside then
                    assert.is_truthy(line:find("^| "), "a log line isn't marked in the summary: " .. line)
                end
            end
            assert.is_false(inside, "a code block is left open")
            -- Failures name the words only: printing a line would make a false CI annotation.
            for _, line in ipairs(runnerLines(r.log)) do
                if line:match("^%s*::") then
                    assert.is_truthy(line:find("^::%a+ title=UI simulator: a run timed out "), "a command that isn't ours")
                end
                for _, word in ipairs({ "seven", "hostile", "carriage", "bad", "set%-env", "##%[" }) do
                    assert.is_falsy(line:find(word), "the log's text reached the job log: " .. word)
                end
            end
        end)
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

    -- #148: the layout checks and the screenshots run at the narrowest layout
    -- and at what most players use.
    it("lists both screen sizes, and the scenario and screenshot jobs run at each (white)", function()
        assert.is_truthy(text:find("\n%s*LAYOUT_SIZES: 1024x768 1920x1080\n"), "the sizes aren't listed, narrowest first")
        -- By name: the simulator job's text names ui-sim-build too (#154).
        local scenarios = jobs["ui-sim"]
        local layoutRun = scenarios.text:gsub("\\\n%s*", " "):match("[^\n]*%-%-exec%-lua @/layout%-lua/layout%.lua[^\n]*")
        assert.is_truthy(layoutRun, "the scenarios aren't run with the sized script")
        assert.is_truthy(layoutRun:find("dump%-tree"), "the sized pass doesn't use dump-tree, which takes a size")
        local limit = tonumber(layoutRun:match("timeout %-s TERM %-k 10 (%d+) docker run"))
        assert.is_truthy(limit and limit >= 60 and limit <= 600, "a sized pass that never exits isn't stopped in time")
        assert.is_truthy(layoutRun:find('%-%-width "${1%%x%*}" %-%-height "${1#%*x}"'), "the size isn't passed")
        assert.is_truthy(scenarios.text:find('for size in $LAYOUT_SIZES; do\n%s*attempt "layout%-$size" [^\n]* sized "$size"\n'),
            "no pass per size")
        local shots = jobWith(order, "shoot")
        assert.is_truthy(shots.text:find("for size in $LAYOUT_SIZES; do\n%s*WIDTH=", 1), "the screenshots aren't taken per size")
        assert.is_truthy(shots.text:find('screenshot --png --width "$WIDTH" --height "$HEIGHT" -o "/shots/$name$SUFFIX.png"', 1, true))
    end)

    it("saves the narrow shots under today's names and the others as <name>-<size>.png (black)", function()
        local shots = jobWith(order, "shoot")
        local pass = shots.text:match("\n(%s*case \"$size\" in[^\n]*)\n")
        assert.is_truthy(pass, "no suffix rule")
        local function suffix(size)
            local f = io.popen("size=" .. size .. "; " .. pass:gsub("^%s+", "") .. "; echo \"[$SUFFIX]\"")
            local out = f:read("*a")
            f:close()
            return out
        end
        assert.are.equal("[]\n", suffix("1024x768"))
        assert.are.equal("[-1920x1080]\n", suffix("1920x1080"))
    end)

    -- #309: the step's time limit, from the shots it can take.
    it("counts the shots, and no shot starts too late for the step's time limit (white, black)", function()
        local shots = jobWith(order, "shoot")
        local function words(name)
            local list = shots.text:match("\n%s*" .. name .. ": ([%w%- ]+)\n")
            assert.is_truthy(list, name .. " isn't listed")
            local n = 0
            for _ in list:gmatch("%S+") do n = n + 1 end
            return n
        end
        -- Every shoot call in shoot_all, a loop's body counted once a turn.
        local body = shots.text:match("shoot_all%(%) {\n(.-)\n%s*}\n%s*for size in")
        assert.is_truthy(body, "no shoot_all")
        local count = 0
        local loopTurns
        for line in body:gmatch("[^\n]+") do
            local list = line:match("^%s*for %w+ in ([^;]+); do%s*$")
            if list then
                loopTurns = list:find("OPTIONS_TABS", 1, true) and words("OPTIONS_TABS")
                    or list:find("WALKTHROUGH_STEPS", 1, true) and words("WALKTHROUGH_STEPS")
                assert.is_truthy(loopTurns, "a loop over " .. list .. " isn't counted")
            elseif line:match("^%s*done%s*$") then
                loopTurns = nil
            elseif line:match("^%s*shoot[ _]") and not line:match("^%s*shoot_all") then
                count = count + (loopTurns or 1)
            end
        end
        -- The comment names the count and the worst case it implies.
        local claimed = tonumber(wow.readFile(path):match("a pass of (%d+) shots can take about %d+ minutes"))
        assert.are.equal(count, claimed, "the step's comment counts " .. tostring(claimed) .. " shots, shoot_all takes " .. count)
        local worst = tonumber(wow.readFile(path):match("a pass of %d+ shots can take about (%d+) minutes"))
        assert.is_true(math.abs(worst - count * 200 / 60) <= 1, "the comment's worst case isn't about " .. count .. " x 200 s")
        -- The cut-off applies in both passes, and a shot started at it finishes inside the step.
        assert.is_truthy(shots.text:find('if [ "$SECONDS" -gt "$SHOT_CUTOFF" ]; then', 1, true), "the cut-off isn't in shoot()")
        assert.is_falsy(shots.text:find('[ -n "$SUFFIX" ] && [ "$SECONDS"', 1, true), "the cut-off is only for the second pass")
        local cutoff = tonumber(shots.text:match("\n%s*SHOT_CUTOFF=(%d+)\n"))
        local timeout = tonumber(shots.text:match("timeout%-minutes: (%d+)\n%s*run: |"))
        assert.is_truthy(cutoff and timeout, "no cut-off or step limit")
        assert.are.equal(cutoff, tonumber(wow.readFile(path):match("after SHOT_CUTOFF %((%d+) s,")), "the comment names another cut-off")
        assert.are.equal(timeout, tonumber(wow.readFile(path):match("inside this\n%s*# step's (%d+) minutes")), "the comment names another limit")
        -- 180 s wait, then about 20 s of checks and clean-up, and the probe's 10 s.
        assert.is_true(timeout * 60 >= cutoff + 200 + 10 + 60, "a shot started at the cut-off can't finish in the step")
        local job = tonumber(shots.text:match("timeout%-minutes: (%d+)\n"))
        assert.is_true(job > timeout, "the job's limit doesn't leave room for the step")
    end)

    -- #310: the one font every run draws and measures in.
    it("pins the simulator's fallback font on every run, and fails if the file is missing (white, black)", function()
        -- In the workflow's own env, so every job has it: an empty one would
        -- pass an unquoted or empty test -f and pin nothing.
        local top = wow.readFile(path):match("^(.-)\njobs:")
        local font = top:match("\n  RENDER_FONT: (/[^\n]+%.ttf)\n")
        assert.is_truthy(font, "no RENDER_FONT in the workflow's env")
        local runs = 0
        for _, job in ipairs({ "ui-sim", "shoot" }) do
            local j = jobs[job == "shoot" and "screenshots" or job]
            local joined = j.text:gsub("\\\n%s*", " ")
            for line in joined:gmatch("[^\n]+") do
                if line:find("/sim/wow%-sim") and line:find("docker run", 1, true) and not line:find("%-%-help") then
                    runs = runs + 1
                    assert.is_truthy(line:find('-e WOW_SIM_FALLBACK_FONT="$RENDER_FONT"', 1, true),
                        "a wow-sim run without the pinned font: " .. line:sub(1, 80))
                end
            end
            -- The render image holds the file, or its build stops.
            assert.is_truthy(j.text:find("fonts%-dejavu%-core[^\n]*\n[^\n]*\n%s*&& test %-f \"$RENDER_FONT\"\n"),
                job .. "'s render image doesn't check the font file exists")
        end
        -- sandbox(), sized() and shoot(), however often they're called.
        assert.are.equal(3, runs, "the runs that pin the font aren't the three that draw text")
        assert.are.equal("DejaVuSans.ttf", font:match("[^/]+$"))
    end)

    -- #153: text a shot or the simulator chooses (file names, logs) reaches
    -- the job log, where the runner reads a line starting "::" (after any
    -- spaces), or holding "##[" anywhere, as a workflow command.
    describe("shot and simulator output in the job log (black)", function()
        local SOURCES = { "%$report%f[^%w]", "%$RUNNER_TEMP/report", "%$RUNNER_TEMP/shots", "%$RUNNER_TEMP/shot%-logs",
            '"%$file"', '"%$log"' }
        local READERS = { "%f[%w]tail%s", "%f[%w]head%s", "%f[%w]ls%s", "%f[%w]grep%s", "%f[%w]cat%s" }

        -- Whether a command line prints shot or simulator output. Paths are
        -- read however they're quoted: "$RUNNER_TEMP"/shots, ${RUNNER_TEMP}/shots.
        local function printsOutput(line)
            if line:find("docker logs", 1, true) or line:find("docker top", 1, true) then return true end
            local plain = line:gsub("%${([%w_]+)}", "$%1"):gsub('"(%$[%w_]+)"/', "%1/")
            for _, reader in ipairs(READERS) do
                if plain:find(reader) then
                    for _, source in ipairs(SOURCES) do
                        if plain:find(source) then return true end
                    end
                end
            end
            return false
        end

        -- shown(), as the workflow defines it, run by bash on the given input.
        local function shown(input, label)
            local definition = wow.readFile(path):match("\n%s*(shown%(%) {[^\n]*})\n")
            assert.is_truthy(definition, "no shown() in " .. path)
            local dir = os.tmpname()
            local f = assert(io.open(dir, "wb"))
            f:write(input)
            f:close()
            local script = assert(io.open(dir .. ".sh", "w"))
            script:write(definition, '\nshown "$1" < "$2"\n')
            script:close()
            local p = io.popen("bash '" .. dir .. ".sh' '" .. (label or "") .. "' '" .. dir .. "' 2>&1")
            local out = p:read("*a")
            p:close()
            os.remove(dir)
            os.remove(dir .. ".sh")
            return out
        end

        -- Lines as the runner splits them: at \n, \r or \r\n.
        local function runnerLines(out)
            local list = {}
            for line in (out:gsub("\r\n?", "\n") .. "\n"):gmatch("([^\n]*)\n") do list[#list + 1] = line end
            return list
        end

        it("filters every tail, head, grep, ls or docker logs of shot or simulator output before the log", function()
            local seen = 0
            for _, job in ipairs(order) do
                for _, step in ipairs(job.steps) do
                    -- Lines in a { ... } block count as filtered only if the
                    -- block ends "} 2>&1 | shown", or goes to the step
                    -- summary, a page the runner doesn't read for commands.
                    local block
                    local function check(line, filtered)
                        seen = seen + 1
                        local toFile = line:find('%s>%s*"%$RUNNER_TEMP/')
                        -- Kept as digits only, in a variable (#173): no command can be made of those.
                        filtered = filtered or line:find("^%s*[%w_]+=%$%([^);&]*| tr %-cd '0%-9'%)%s*|| true%s*$") ~= nil
                            or line:find("^%s*[%w_]+=%$%([^);&]*| tr %-cd '0%-9'%)%s*$") ~= nil
                        assert.is_truthy(filtered or toFile or line:find("| shown", 1, true),
                            job.name .. " prints unfiltered output: " .. line)
                        -- docker logs replays the container's stderr on its own.
                        if not filtered and not toFile and line:find("docker %l+ ") then
                            assert.is_truthy(line:find("2>&1 |", 1, true),
                                job.name .. " filters only stdout: " .. line)
                        end
                    end
                    for _, line in ipairs(splitLines((step.text:gsub("\\\n%s*", " ")))) do
                        if line:match("^%s*{%s*$") then
                            block = {}
                        elseif block and line:match("^%s*}") then
                            local filtered = line:match("^%s*} 2>&1 | shown%s*$")
                                or line:match('^%s*} >> "%$GITHUB_STEP_SUMMARY"%s*$')
                            for _, held in ipairs(block) do check(held, filtered ~= nil) end
                            block = nil
                        elseif printsOutput(line) then
                            if block then block[#block + 1] = line else check(line, false) end
                        end
                    end
                    assert.is_nil(block, job.name .. " has a { block that never ends")
                end
            end
            assert.is_true(seen >= 10, "expected the report, digest, shot log and docker logs prints, found " .. seen)
        end)

        it("defines shown() the same way in every step that uses it", function()
            local definition = wow.readFile(path):match("\n%s*(shown%(%) {[^\n]*})\n")
            for _, job in ipairs(order) do
                for _, step in ipairs(job.steps) do
                    if step.text:find("| shown", 1, true) then
                        assert.is_truthy(step.text:find("\n%s*" .. definition:gsub("%p", "%%%0") .. "\n"),
                            job.name .. " uses shown() without the same definition")
                    end
                end
            end
            -- Every mark it's given shows something before the text.
            for label in text:gmatch('| shown "([^"]*)"') do
                assert.is_truthy(label:find("%S"), "shown() is given a mark of only spaces")
            end
        end)

        it("never lets a line reach the runner as a command", function()
            local hostile = "::error::one\n   ::warning::two\n\t::stop-commands::t\nok\r::error::three\n"
                .. "x ##[set-env name=A;]b\nend\r\n::add-mask::four"
            for _, label in ipairs({ false, "  game> " }) do
                local out = shown(hostile, label or nil)
                for _, word in ipairs({ "one", "two", "three", "four", "set-env" }) do
                    assert.is_truthy(out:find(word, 1, true), "a line was lost: " .. word)
                end
                local split = runnerLines(out)
                -- Failures name the line by number: printing it would make a
                -- false CI annotation.
                for i, line in ipairs(split) do
                    assert.is_falsy(line:match("^%s*::"), "output line " .. i .. " is read as a command")
                    assert.is_falsy(line:find("##[", 1, true), "output line " .. i .. " is read as an old-style command")
                end
            end
        end)

        it("keeps ordinary lines readable, after a mark (white)", function()
            assert.are.equal("| LAYOUT ok 1024x768 FriendlyForeverOptionsPanel\n| second\n",
                shown("LAYOUT ok 1024x768 FriendlyForeverOptionsPanel\nsecond\n"))
            assert.are.equal("  button> loaded in 3 s\n", shown("loaded in 3 s\n", "  button> "))
        end)

        it("never prints a published file's name before checking it's plain", function()
            local publish = jobs["publish-screenshots"]
            local check = publish.text:find('case "$name" in *[!A-Za-z0-9._-]*)', 1, true)
            assert.is_truthy(check, "no plain-name check in the publish job")
            local checkLine = publish.text:match('[^\n]*case "%$name" in [^\n]*')
            assert.is_falsy(checkLine:find("echo[^;]*%$name"), "an unsafe name is printed: " .. checkLine)
            local first = publish.text:find("echo[^\n]*%$name")
            assert.is_true(first == nil or first > check, "a name is printed before it's checked")
        end)
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

    -- #261: a note still waiting in changes/ (or under ### Unreleased) would
    -- be left out of the release notes. verify checks it before asking CI, so
    -- the #241 fast path never skips it, and the upload writes its notes the
    -- same way.
    it("refuses a release that left a changelog note ungathered, on the fast path too (white, black)", function()
        local verify = jobWith(order, "make test")
        local check = indexOf(verify.steps, "make release%-notes RELEASE=1")
        local ask = indexOf(verify.steps, "id:%s*ci%s")
        assert.is_truthy(check, "verify doesn't check every changelog note was gathered")
        assert.is_true(check < ask, "the gathered check comes after asking CI")
        assert.is_falsy(verify.steps[check].text:find("if:", 1, true), "the gathered check can be skipped")
        local release = jobWith(order, "BigWigsMods/packager@")
        local notes = indexOf(release.steps, "make release%-notes")
        assert.is_truthy(release.steps[notes].text:find("make release-notes RELEASE=1\n", 1, true),
            "the uploaded notes don't check every note was gathered")
        assert.is_truthy(wow.readFile("Makefile"):find("./scripts/release-notes.sh $(if $(RELEASE),--release)", 1, true),
            "make release-notes RELEASE=1 doesn't pass --release")
    end)

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

    -- #241: verify trusts main's required check on the tagged commit when it
    -- passed, runs lint and the tests itself when it can't tell, and fails
    -- when it failed. The job itself is never skipped and never lets a
    -- failure through.
    describe("trusts main's required check on the tagged commit (#241)", function()
        local verify, ciStep, ciIndex

        setup(function()
            verify = jobWith(order, "make test")
            ciIndex = indexOf(verify.steps, "id:%s*ci%s")
            ciStep = ciIndex and verify.steps[ciIndex]
        end)

        it("keeps verify a required, unskippable job with read-only access (black)", function()
            assert.is_falsy(verify.keys["if"], "verify can be skipped")
            assert.is_falsy(verify.keys["continue-on-error"], "verify's failure can be ignored")
            assert.is_falsy(verify.text:find("continue%-on%-error"), "a verify step's failure can be ignored")
            local permissions = verify.text:match("\n    permissions:\n(.-)\n    steps:")
            assert.are.equal("      contents: read\n      actions: read", permissions, "verify's access")
            assert.is_falsy(verify.text:find("secrets%."), "verify can read secrets")
            local release = jobWith(order, "BigWigsMods/packager@")
            assert.is_truthy(release.text:find("\n    needs: verify\n", 1, true), "release doesn't need verify")
            assert.is_falsy(release.keys["if"], "release has a condition that could run it without verify")
        end)

        it("checks the tag first, then asks CI, and skips only lint and the tests when CI passed (white, black)", function()
            local tag = indexOf(verify.steps, "merge%-base %-%-is%-ancestor")
            assert.is_truthy(ciStep, "verify doesn't ask main's CI")
            assert.is_true(tag < ciIndex, "the tag is checked after CI is asked")
            assert.is_falsy(verify.steps[tag].text:find("if:"), "the tag check can be skipped")
            assert.is_falsy(ciStep.text:find("\n        if:"), "asking CI can be skipped")
            -- Only the step that asks CI holds the job's read-only token.
            for i, step in ipairs(verify.steps) do
                assert.are.equal(i == ciIndex, step.text:find("github.token", 1, true) ~= nil, "step " .. i .. "'s token")
            end
            local skippable = 0
            for i, step in ipairs(verify.steps) do
                local condition = step.text:match("\n        if:%s*([^\n]*)")
                if condition then
                    -- != 'true': an empty answer runs the tests.
                    assert.are.equal("${{ steps.ci.outputs.passed != 'true' }}", condition, "step " .. i)
                    assert.is_true(i > ciIndex, "step " .. i .. " is skipped before CI is asked")
                    skippable = skippable + 1
                end
            end
            assert.are.equal(3, skippable, "expected Python, the build dependencies, and lint and test to be skippable")
            local tests = indexOf(verify.steps, "make test")
            assert.is_truthy(verify.steps[tests].text:find("make lint", 1, true), "lint isn't run with the tests")
            assert.is_truthy(verify.steps[tests].text:find("\n        if:", 1, true), "the tests can't be skipped")
        end)

        -- ci.yml's required job is found by its name; a renamed or duplicated
        -- job would leave nothing to trust (and run the tests), never the wrong job.
        it("reads the check by the name ci.yml gives it (white)", function()
            local ci = parseWorkflow(".github/workflows/ci.yml")
            assert.is_truthy(ci.check, "ci.yml has no check job")
            assert.is_falsy(ci.check.keys.name, "the check job has a display name, so its check isn't called check")
            assert.is_falsy(ci.check.keys.strategy, "the check job is a matrix, so its check isn't called check")
            assert.is_truthy(ciStep.text:find('actions/workflows/ci.yml/runs?head_sha=$GITHUB_SHA&event=push&branch=main', 1, true),
                "verify doesn't ask for main's CI runs on this commit")
        end)

        -- Runs the step's own script against a fake gh that answers from files.
        it("passes on success, runs the tests when unsure, and fails on a failed check (white, black)", function()
            -- GitHub runs a step with no shell: key as bash -e, and so does this test.
            -- Nowhere: a workflow- or job-level defaults: could set one too.
            assert.is_falsy(withoutComments(wow.readFile(path)):find("shell:"), "release.yml names a shell")
            local script = ciStep.text:match("run: |\n(.*)$")
            assert.is_truthy(script and script:find("set %-u"), "couldn't find the script that asks CI")
            local dir = io.popen("mktemp -d"):read("*l")
            local body = io.open(dir .. "/ask.sh", "w")
            body:write((script:gsub("\n          ", "\n"):gsub("^%s+", "")))
            body:close()
            os.execute("mkdir '" .. dir .. "/bin'")
            local gh = io.open(dir .. "/bin/gh", "w")
            gh:write("#!/bin/sh\n"
                .. "echo \"$*\" >> \"$FAKE/calls\"\n"
                .. "[ \"$1\" = api ] || exit 9\n"
                .. "case \"$2\" in\n"
                .. "  repos/o/r/actions/workflows/ci.yml/runs\\?*) f=runs ;;\n"
                .. "  repos/o/r/actions/runs/*/jobs\\?*) id=${2#repos/o/r/actions/runs/}; f=jobs-${id%%/*} ;;\n"
                .. "  *) exit 9 ;;\n"
                .. "esac\n"
                .. "[ -f \"$FAKE/$f.json\" ] || exit 1\n"
                .. "cat \"$FAKE/$f.json\"\n")
            gh:close()
            os.execute("chmod +x '" .. dir .. "/bin/gh'")
            local sha = ("a1"):rep(20)

            local function run(fields)
                local list = {}
                for k, v in pairs({ id = 7, head_sha = sha, event = "push", head_branch = "main",
                    path = ".github/workflows/ci.yml", conclusion = "success", repo = "o/r" }) do
                    if fields[k] == nil then fields[k] = v end
                end
                for _, k in ipairs({ "id", "head_sha", "event", "head_branch", "path", "conclusion" }) do
                    local v = fields[k]
                    list[#list + 1] = ("%q: %s"):format(k, v == "null" and "null" or type(v) == "number" and v or ("%q"):format(v))
                end
                list[#list + 1] = ('"head_repository": {"full_name": %q}'):format(fields.repo)
                return "{" .. table.concat(list, ", ") .. "}"
            end
            local function jobs(status, conclusion, extra)
                local list = { ('{"name": "lint-package", "status": "completed", "conclusion": "success"}') }
                if status then
                    list[#list + 1] = ('{"name": "check", "status": %q, "conclusion": %s}'):format(status,
                        conclusion and ("%q"):format(conclusion) or "null")
                end
                if extra then list[#list + 1] = extra end
                return '{"jobs": [' .. table.concat(list, ", ") .. "]}"
            end
            local function ask(files, env)
                os.execute("rm -f '" .. dir .. "'/*.json '" .. dir .. "/calls' '" .. dir .. "/out' && touch '" .. dir .. "/out'")
                for name, content in pairs(files) do
                    local f = io.open(dir .. "/" .. name .. ".json", "w")
                    f:write(content)
                    f:close()
                end
                local ok = os.execute("cd '" .. dir .. "' && PATH='" .. dir .. "/bin':\"$PATH\" FAKE='" .. dir .. "' GITHUB_OUTPUT='"
                    .. dir .. "/out' GITHUB_REPOSITORY=o/r GITHUB_SHA='" .. (env or sha) .. "' bash -e ask.sh >/dev/null 2>&1") == 0
                local out = io.open(dir .. "/out"):read("*a")
                return ok and (out:match("^passed=(%a+)\n$") or "no answer") or "failed"
            end
            local function runs(...) return '{"workflow_runs": [' .. table.concat({ ... }, ", ") .. "]}" end
            local cases = {
                { "success", { runs = runs(run({})), ["jobs-7"] = jobs("completed", "success") }, "true" },
                { "not finished", { runs = runs(run({ conclusion = "null" })), ["jobs-7"] = jobs("in_progress") }, "false" },
                { "queued", { runs = runs(run({ conclusion = "null" })), ["jobs-7"] = jobs("queued") }, "false" },
                { "check not started", { runs = runs(run({ conclusion = "null" })), ["jobs-7"] = jobs() }, "false" },
                { "failed", { runs = runs(run({ conclusion = "failure" })), ["jobs-7"] = jobs("completed", "failure") }, "failed" },
                { "no run", { runs = runs() }, "false" },
                -- A run a newer push to main cancelled reports a failed check; it proves nothing.
                { "cancelled run", { runs = runs(run({ conclusion = "cancelled" })), ["jobs-7"] = jobs("completed", "failure") }, "false" },
                { "cancelled check", { runs = runs(run({ conclusion = "cancelled" })), ["jobs-7"] = jobs("completed", "cancelled") }, "false" },
                { "skipped check", { runs = runs(run({})), ["jobs-7"] = jobs("completed", "skipped") }, "false" },
                { "timed out", { runs = runs(run({ conclusion = "failure" })), ["jobs-7"] = jobs("completed", "timed_out") }, "false" },
                -- Only CI's own run from a push to main in this repository, on this commit.
                { "another commit", { runs = runs(run({ head_sha = ("b2"):rep(20) })), ["jobs-7"] = jobs("completed", "success") }, "false" },
                { "a pull request", { runs = runs(run({ event = "pull_request" })), ["jobs-7"] = jobs("completed", "success") }, "false" },
                { "another branch", { runs = runs(run({ head_branch = "pr" })), ["jobs-7"] = jobs("completed", "success") }, "false" },
                { "another workflow", { runs = runs(run({ path = ".github/workflows/ui-sim.yml" })), ["jobs-7"] = jobs("completed", "success") }, "false" },
                { "a fork's branch called main", { runs = runs(run({ repo = "fork/r" })), ["jobs-7"] = jobs("completed", "success") }, "false" },
                { "two jobs called check", { runs = runs(run({})), ["jobs-7"] = jobs("completed", "success",
                    '{"name": "check", "status": "completed", "conclusion": "success"}') }, "false" },
                -- Two runs: a failure anywhere stops the release; a pass anywhere else counts.
                { "a failed and a passed run", { runs = runs(run({ id = 8 }), run({ conclusion = "failure" })),
                    ["jobs-8"] = jobs("completed", "success"), ["jobs-7"] = jobs("completed", "failure") }, "failed" },
                { "an unfinished and a passed run", { runs = runs(run({ conclusion = "null" }), run({ id = 8 })),
                    ["jobs-7"] = jobs("in_progress"), ["jobs-8"] = jobs("completed", "success") }, "true" },
                -- API trouble or nonsense: run the tests.
                { "no runs answer", {}, "false" },
                { "no jobs answer", { runs = runs(run({})) }, "false" },
                { "runs not JSON", { runs = "<html>" }, "false" },
                { "jobs not JSON", { runs = runs(run({})), ["jobs-7"] = "<html>" }, "false" },
                { "an odd run id", { runs = runs(run({ id = '7/../../x' })), ["jobs-7"] = jobs("completed", "success") }, "false" },
            }
            for _, case in ipairs(cases) do
                assert.are.equal(case[3], ask(case[2]), case[1])
            end
            -- The question names the commit, the event and the branch.
            ask({ runs = runs(run({})), ["jobs-7"] = jobs("completed", "success") })
            local calls = io.open(dir .. "/calls"):read("*a")
            assert.is_truthy(calls:find("api repos/o/r/actions/workflows/ci.yml/runs?head_sha=" .. sha
                .. "&event=push&branch=main&per_page=100\n", 1, true), calls)
            assert.is_truthy(calls:find("api repos/o/r/actions/runs/7/jobs?per_page=100\n", 1, true), calls)
            -- A run on another commit never counts, whatever the API is asked.
            assert.are.equal("false", ask({ runs = runs(run({})), ["jobs-7"] = jobs("completed", "success") }, ("b2"):rep(20)))
            os.execute("rm -rf '" .. dir .. "'")
        end)
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
            "AGENTS.md", ".busted", ".luacheckrc", ".gitignore" }) do
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
        -- The heading, not the word: a released note may name it (#261's own does).
        for _, line in ipairs(require("spec.support.changelog").Lines(wow.readFile("RELEASE_NOTES.md"))) do
            assert.is_nil(line:match("^%s*#+%s*Unreleased"), "the notes hold an Unreleased heading: " .. line)
        end
    end)

    -- package.sh moves a finished zip into place, so the zip is
    -- never missing while another run (or a test) uses it.
    it("package.sh never removes or damages the zip while other runs rebuild it", function()
        local zip = run("./scripts/package.sh"):match("([^\n]*%.zip)")
        assert.is_truthy(zip, "package script did not report a zip")
        local script = [[
            for i in 1 2 3; do ./scripts/package.sh >/dev/null & done
            missing=0
            while [ -n "$(jobs -r)" ]; do unzip -tqq "$1" >/dev/null 2>&1 || missing=$((missing+1)); done
            wait
            echo "missing=$missing"
            # Another make check may be building in this dist/ too: its temporary
            # file goes when it finishes, a leaked one never does.
            left=1
            for i in $(seq 1 100); do
                left=$(ls -A dist | grep -c '^\.' || true)
                [ "$left" = 0 ] && break
                sleep 0.2
            done
            echo "$left"
        ]]
        local out = run("bash -c '" .. script:gsub("'", "'\\''") .. "' _ \"" .. zip .. "\"")
        assert.is_truthy(out:find("missing=0", 1, true), out)
        assert.is_truthy(out:find("missing=0\n0\n", 1, true), "temporary files left in dist: " .. out)
    end)

    it("release-notes.sh fails on a changelog with no version section and keeps the old notes", function()
        local dir = os.tmpname()
        os.remove(dir)
        os.execute('mkdir -p "' .. dir .. '"')
        local function write(name, body)
            local file = io.open(dir .. "/" .. name, "wb")
            file:write(body)
            file:close()
        end
        write("CHANGELOG.md", "# Changelog\n\n### Unreleased\n\n- x\n")
        write("NOTES.md", "old notes\n")
        local out, code = run('./scripts/release-notes.sh "' .. dir .. '/CHANGELOG.md" "' .. dir .. '/NOTES.md"')
        local kept = io.open(dir .. "/NOTES.md"):read("*a")
        local left = run('ls -A "' .. dir .. '" | grep -c "^NOTES.md\\." || true')
        os.execute('rm -rf "' .. dir .. '"')
        assert.are_not.equal(0, code)
        assert.is_truthy(out:find("No ## version section", 1, true), out)
        assert.are.equal("old notes\n", kept)
        assert.is_truthy(left:find("^0"), "temporary notes file left behind: " .. left)
    end)

    -- A temporary file in another folder (a /tmp on its own filesystem) would
    -- make the final mv a copy, and the race would be back (#178).
    it("package.sh and release-notes.sh make their temporary files beside the output", function()
        local bin = os.tmpname()
        os.remove(bin)
        os.execute('mkdir -p "' .. bin .. '"')
        local real = run("command -v mktemp"):match("([^\n]+)")
        local shim = io.open(bin .. "/mktemp", "wb")
        shim:write('#!/bin/bash\necho "$*" >> "' .. bin .. '/calls"\nexec "' .. real .. '" "$@"\n')
        shim:close()
        os.execute('chmod +x "' .. bin .. '/mktemp"')
        local pkg = run('PATH="' .. bin .. ':$PATH" ./scripts/package.sh')
        local notes = run('PATH="' .. bin .. ':$PATH" ./scripts/release-notes.sh')
        local file = io.open(bin .. "/calls")
        local calls = file and file:read("*a") or ""
        if file then file:close() end
        os.execute('rm -rf "' .. bin .. '"')
        assert.is_truthy(pkg:find("%.zip"), pkg)
        assert.is_truthy(notes:find("RELEASE_NOTES.md", 1, true), notes)
        assert.is_truthy(calls:find("/dist/.FriendlyForever-", 1, true), "package.sh's temp file isn't in dist/: " .. calls)
        assert.is_truthy(calls:find("/RELEASE_NOTES.md.", 1, true), "release-notes.sh's temp file isn't beside its output: " .. calls)
    end)

    it("two package.sh runs started together both succeed", function()
        local out = run("./scripts/package.sh >/dev/null & p=$!; ./scripts/package.sh >/dev/null; a=$?; wait $p; b=$?; echo rc=$a$b")
        assert.is_truthy(out:find("rc=00", 1, true), out)
    end)

    it("release-notes.sh never leaves the notes empty while other runs rewrite them", function()
        local script = [[
            ./scripts/release-notes.sh >/dev/null
            for i in 1 2 3; do ./scripts/release-notes.sh >/dev/null & done
            bad=0
            while [ -n "$(jobs -r)" ]; do [ -s RELEASE_NOTES.md ] || bad=$((bad+1)); done
            wait
            echo "bad=$bad"
            left=1
            for i in $(seq 1 100); do
                left=$(ls -A | grep -c '^RELEASE_NOTES.md\.' || true)
                [ "$left" = 0 ] && break
                sleep 0.2
            done
            echo "$left"
        ]]
        local out = run("bash -c '" .. script:gsub("'", "'\\''") .. "'")
        assert.is_truthy(out:find("bad=0\n0\n", 1, true), out)
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
        for _, path in ipairs({ "CONTRIBUTING.md", "README.md", "docs/launch-day-runbook.md" }) do
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

        -- #241: merging waits only for the required check, a patch release of
        -- documentation-only fixes is one pull request, and verify trusts main's
        -- check. AGENTS.md points agents to both rules.
        it("CONTRIBUTING.md says merges wait only for the required check and doc-only patch releases are one PR (white)", function()
            local flat = wow.readFile("CONTRIBUTING.md"):gsub("%s+", " ")
            local lands = flat:match("## How changes land (.-) ## ") or ""
            assert.is_truthy(lands:find("A pull request can merge as soon as the required `check` is green", 1, true),
                "How changes land doesn't say a merge waits only for the required check")
            assert.is_truthy(lands:find("the report-only jobs (the UI simulator, screenshots, CodeQL) never gate a merge", 1, true),
                "How changes land doesn't say the report-only jobs never gate a merge")
            local releasing = flat:match("## Releasing %(maintainer%) (.*)$") or ""
            assert.is_truthy(releasing:find("A patch release of documentation-only fixes is one pull request", 1, true),
                "Releasing doesn't say a documentation-only patch release is one pull request")
            assert.is_truthy(releasing:find("A release with code changes keeps its own release PR", 1, true))
            assert.is_truthy(releasing:find("if it failed, the release stops", 1, true), "Releasing doesn't say what verify does")
            local agents = wow.readFile("AGENTS.md"):gsub("%s+", " ")
            assert.is_truthy(agents:find("a PR can merge once the required `check` is green", 1, true), "AGENTS.md")
            assert.is_truthy(agents:find("A patch release of documentation-only fixes is one PR with the fix", 1, true), "AGENTS.md")
        end)

        -- #229: a ready PR only behind main is updated by the owner; overlap or a
        -- conflict still goes to the developer and the reviewers.
        it("the Update branch rule is written once in CONTRIBUTING.md and only referenced elsewhere (white, black)", function()
            local flat = wow.readFile("CONTRIBUTING.md"):gsub("%s+", " ")
            local rule = flat:match("#### Only behind `main` (.-) ## ") or ""
            assert.is_truthy(rule:find("**No file in both lists and no conflict: update branch only.**", 1, true), "update-branch case")
            assert.is_truthy(rule:find("The developer does nothing: no merge, no push, no reviewer re-run.", 1, true))
            assert.is_truthy(rule:find("counts as met; the coordinator's message to the maintainer, naming the pull request and the two file lists, is the record", 1, true))
            assert.is_truthy(rule:find("**A file in both lists, or any conflict: developer must merge.**", 1, true), "developer case")
            assert.is_truthy(rule:find("the reviewers confirm the merge and the resolutions", 1, true), "reviewers still confirm")
            assert.is_truthy(rule:find("The coordinator tells the maintainer which case each waiting pull request is in", 1, true))
            local ready = flat:match("### Ready for review (.-) #### Only behind") or ""
            assert.is_truthy(ready:find("only behind `main` counts as up to date", 1, true), "ready checklist")
            for _, path in ipairs({ "AGENTS.md", "CLAUDE.md", ".claude/skills/after-merge/SKILL.md", ".claude/skills/coordinator/SKILL.md", ".claude/skills/merge-order/SKILL.md" }) do
                local text = wow.readFile(path):gsub("%s+", " ")
                assert.is_truthy(text:find("#only-behind-main", 1, true), path .. " doesn't reference the rule")
                assert.is_falsy(text:find("update branch only.**", 1, true), path .. " restates the rule")
                assert.is_falsy(text:find("developer must merge.**", 1, true), path .. " restates the rule")
            end
            -- Whole sentences, so a changed condition or a changed actor fails (#119).
            local function has(path, sentence)
                local text = wow.readFile(path):gsub("%s+", " ")
                assert.is_truthy(text:find(sentence, 1, true), path .. " lost: " .. sentence)
            end
            has("CONTRIBUTING.md", "Unchanged: the developer merges `main`, resolves, and the reviewers confirm the merge and the resolutions.")
            has(".claude/skills/after-merge/SKILL.md", "If the PR shares no file with the merge and has no conflict, do nothing: the owner clicks Update branch")
            has(".claude/skills/coordinator/SKILL.md", 'then tell the owner, naming the PR, "update branch only" or "developer must merge"')
            has(".claude/skills/coordinator/SKILL.md", 'Only for "developer must merge", tell its driver to merge `main` in (the `after-merge` skill).')
            has(".claude/skills/coordinator/SKILL.md", "only behind `main` (no shared file, no conflict), it is still ready")
            has(".claude/skills/coordinator/SKILL.md", "Otherwise it isn't ready: tell its driver to merge `main` in (the `after-merge` skill), and don't report it to the owner yet.")
            has(".claude/skills/merge-order/SKILL.md", "Say so, and tell its driver to merge `main` in (the `after-merge` skill). Exception:")
            has(".claude/skills/merge-order/SKILL.md", "only behind `main` (no shared file, no trial-merge conflict) is still ready")
            has("AGENTS.md", "only behind `main` (no shared file, no conflict) is not for the driver")
            -- Written once: each label appears exactly once in CONTRIBUTING.md.
            for _, label in ipairs({ "update branch only.**", "developer must merge.**" }) do
                local _, count = flat:gsub(label:gsub("%p", "%%%0"), "")
                assert.are.equal(1, count, "CONTRIBUTING.md has " .. count .. " copies of " .. label)
            end
            local afterMerge = wow.readFile(".claude/skills/after-merge/SKILL.md"):gsub("%s+", " ")
            assert.is_truthy(afterMerge:find("a conflict was resolved, the reviewers confirm the merge", 1, true), "overlap/conflict still reviewed")
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
        local all = splitLines(text)
        for at, line in ipairs(all) do
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
            -- them, must still name a source (#122, #130): an issue or pull
            -- request, a link, or a file name in code quotes (no spaces, so
            -- `see guide` isn't one). Words alone don't count. The header
            -- row, just above the separator, needs none, and nor does the
            -- separator row, where every cell is dashes with optional colons;
            -- a blank row isn't one.
            local cell = row and withoutLaunchCheckLinks(row:match("([^|]*)$")):gsub("%[[^%]]*%]%(%)", "")
            local nextRow = all[at + 1] and all[at + 1]:match("^|(.*)|%s*$")
            local header = row and nextRow and isSeparatorRow(nextRow)
            if cell and not header and not isSeparatorRow(row)
                and not (cell:find("#%d+") or cell:find("https?://") or cell:find("`[^`%s]+`")) then
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

    -- Model choice (#182): a family alias and an effort level in front matter,
    -- and never a dated model ID anywhere sessions read.
    local FAMILIES = { haiku = true, sonnet = true, opus = true, fable = true }
    local EFFORTS = { low = true, medium = true, high = true, xhigh = true, max = true }

    local function modelProblems(text)
        local fields = frontMatter(text)
        local problems = {}
        if not FAMILIES[fields.model or ""] then
            problems[#problems + 1] = "model isn't a family alias: " .. tostring(fields.model)
        end
        if not EFFORTS[fields.effort or ""] then
            problems[#problems + 1] = "effort isn't a level: " .. tostring(fields.effort)
        end
        return problems
    end

    -- Dated or versioned model IDs, such as claude-sonnet-4-5 or claude-3-opus.
    local function modelIds(text)
        local found = {}
        for id in text:lower():gmatch("claude%-[%w%-%.]*%d[%w%-%.]*") do found[#found + 1] = id end
        return found
    end

    local AGENTS = { "lua-architect", "lua-tester" }
    local SKILLS = { "after-merge", "merge-order", "coordinator" }
    local DOCS = { "docs/forever-facts.md", "docs/simulated-client.md", "docs/ui-simulator.md",
        "docs/agent-facts.md" }

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

        it("report a table row whose source cell holds only words, besides its #50 links (#130)", function()
            local head = "| Quirk | Workaround | Source |\n|---|---|---|\n"
            for _, cell in ipairs({ "See #50", "launch check, #50", "See the guide", "`see guide`", "``", "`a b`",
                "words (#50)", "`` `" }) do
                assert.are.equal(1, #factProblems(head .. "| It wraps. | Measure it. | " .. cell .. " |\n"), cell)
            end
            for _, cell in ipairs({ "#50, #116", "#50, `ui-sim.yml`", "#50, [a guide](https://example.org)",
                "See #116", "`uitests/scenarios.lua`", "https://example.org/x", "#102 (from `src/c_map.rs`)" }) do
                assert.are.same({}, factProblems(head .. "| It wraps. | Measure it. | " .. cell .. " |\n"), cell)
            end
            -- A header row passes, with or without alignment colons, and so does
            -- the second table's header after a first; its rows are held to it.
            assert.are.same({}, factProblems("| Quirk | Workaround | Source |\n|:---|---:|:-:|\n"))
            local two = head .. "| A. | B. | #91 |\n\n| Other | Source |\n|---|---|\n| C. | words |\n"
            assert.are.equal(1, #factProblems(two))
            -- A row of words with no separator under it is not a header.
            assert.are.equal(1, #factProblems(head .. "| A. | B. | #91 |\n| Quirk | Workaround | Source |\n"))
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

    describe("the model checks themselves", function()
        local function file(parts) return table.concat(parts, "\n") end

        it("pass a family alias with an effort level, for each family and level", function()
            for family in pairs(FAMILIES) do
                for effort in pairs(EFFORTS) do
                    assert.are.same({}, modelProblems(file({ "---", "name: x", "model: " .. family,
                        "effort: " .. effort, "---" })), family .. " " .. effort)
                end
            end
        end)

        it("catch a missing, inherited, vague or dated model, and a missing or unknown effort (black)", function()
            for _, model in ipairs({ "inherit", "fastest", "Opus", "claude-opus-4-1", "" }) do
                assert.are.equal(1, #modelProblems(file({ "---", "model: " .. model, "effort: high", "---" })),
                    model)
            end
            assert.are.equal(1, #modelProblems(file({ "---", "effort: high", "---" })), "no model")
            assert.are.equal(1, #modelProblems(file({ "---", "model: opus", "effort: huge", "---" })), "huge")
            assert.are.equal(1, #modelProblems(file({ "---", "model: opus", "---" })), "no effort")
            assert.are.equal(2, #modelProblems("model: opus\neffort: high\n"), "no front matter")
        end)

        it("find dated and versioned model IDs, and leave aliases and other words alone", function()
            assert.are.same({ "claude-opus-4-1", "claude-3-5-sonnet-20241022", "claude-haiku-5-5" },
                modelIds("Use claude-opus-4-1, Claude-3-5-Sonnet-20241022 or `claude-haiku-5-5`."))
            assert.are.same({}, modelIds("opus, sonnet, claude.ai/code, claude-code-guide, claude/182-x"))
        end)
    end)

    for _, name in ipairs(AGENTS) do
        it(".claude/agents/" .. name .. ".md names its model family alias and effort level", function()
            assert.are.same({}, modelProblems(wow.readFile(".claude/agents/" .. name .. ".md")))
        end)
    end

    -- The skills against CLAUDE.md's table (#182, #242): the coordinator runs on
    -- opus; after-merge and merge-order run inside other sessions, so a model:
    -- would switch that session's family mid-turn, and they set none. No skill
    -- sets an effort: the owner hasn't set one for developers or the coordinator.
    it("the skills' model and effort match CLAUDE.md's table", function()
        local EXPECTED = { coordinator = "opus", ["after-merge"] = false, ["merge-order"] = false }
        for _, name in ipairs(SKILLS) do
            local fields = frontMatter(wow.readFile(".claude/skills/" .. name .. "/SKILL.md"))
            assert.are.same({ EXPECTED[name] or nil, nil }, { fields.model, fields.effort }, name)
        end
        local body = wow.readFile("CLAUDE.md"):match("\n## Models and effort\n(.-)\n## ") or ""
        assert.is_truthy(body:find("| The coordinator (`coordinator` skill) | `opus` | session default |", 1, true),
            "the table's coordinator row")
        assert.is_falsy(body:find("trial in progress", 1, true), "no trial cell is left")
        assert.is_truthy(body:find("the coordinator session itself is started on `opus`", 1, true),
            "the coordinator session itself runs on opus")
    end)

    -- The owner's choice on #182: opus at high effort for both reviewers.
    it("the reviewer agents run on opus at high effort", function()
        for _, name in ipairs(AGENTS) do
            local fields = frontMatter(wow.readFile(".claude/agents/" .. name .. ".md"))
            assert.are.same({ "opus", "high" }, { fields.model, fields.effort }, name)
        end
    end)

    it("CLAUDE.md, AGENTS.md, the PR template, the agents and the skills name no dated model ID", function()
        local paths = { "CLAUDE.md", "AGENTS.md", ".github/pull_request_template.md" }
        for _, name in ipairs(AGENTS) do paths[#paths + 1] = ".claude/agents/" .. name .. ".md" end
        for _, name in ipairs(SKILLS) do paths[#paths + 1] = ".claude/skills/" .. name .. "/SKILL.md" end
        for _, path in ipairs(paths) do assert.are.same({}, modelIds(wow.readFile(path)), path) end
    end)

    it("CLAUDE.md maps each kind of job to a family alias and an effort level", function()
        local text = wow.readFile("CLAUDE.md")
        local body = text:match("\n## Models and effort\n(.-)\n## ") or ""
        for _, row in ipairs({
            "| Lookups, searches and routine checks | `haiku` | `low` |",
            "| Developer sessions: building and fixing | `sonnet` | session default |",
            "| Developer sessions on security-sensitive and release-workflow changes, specs and hard bugs | `opus` | `high` |",
            "| The coordinator (`coordinator` skill) | `opus` | session default |",
            "| The architecture and testing reviews (`lua-architect`, `lua-tester`) | `opus` | `high` |",
        }) do
            assert.is_truthy(body:find(row, 1, true), row)
        end
        assert.is_truthy(body:find("**A review served by the wrong family doesn't count.** Run it again on the"
            .. " family its agent names, or flag it to the owner.", 1, true), "the wrong-family rule")
    end)

    it("CLAUDE.md, the agents and the PR template record the model that served each review", function()
        local claude = wow.readFile("CLAUDE.md")
        assert.is_truthy(claude:find("- **Which model reviewed:** each verdict names the model that served it,",
            1, true), "CLAUDE.md's review rule")
        for _, name in ipairs(AGENTS) do
            local output = section(wow.readFile(".claude/agents/" .. name .. ".md"), "Output")
            local model = output:find("**Model,** on one line starting `Model:`", 1, true)
            local verdict = output:find("**The verdict, as the last line", 1, true)
            assert.is_truthy(model and verdict and model < verdict, name .. " names its model before the verdict")
        end
        local template = wow.readFile(".github/pull_request_template.md")
        for _, line in ipairs({ "\n- Lua architecture review: model , effort\n",
            "\n- Lua testing review: model , effort\n", "doesn't count: run it again, or flag it to the owner." }) do
            assert.is_truthy(template:find(line, 1, true), line)
        end
    end)

    -- #318: a reviewer can't observe its effort, so the record is the configured one.
    it("CLAUDE.md has reviewers launched with effort high and records effort as configured (#318)", function()
        local claude = wow.readFile("CLAUDE.md")
        assert.is_truthy(claude:find("- **Launching a reviewer:** pass `effort: high` in the Agent call", 1, true),
            "the launch rule")
        local records = claude:match("\n## Review records\n(.*)$") or ""
        local reviewed = records:match("%- %*%*Which model reviewed:%*%*[^\n]*") or ""
        assert.is_truthy(reviewed:find("names the model that served it, its family, just above the verdict line",
            1, true), "the model line")
        assert.is_nil(reviewed:find("and the effort", 1, true), "no reported effort")
        local bullet = records:match("%- %*%*Effort is recorded as configured, not as reported %(#318%)%.%*%*[^\n]*") or ""
        for _, rule in ipairs({
            "So the PR records the effort you configured (the frontmatter's `high`, plus the Agent call's `effort`"
                .. " parameter), and never a number or level a reviewer reports about itself.",
            "Say plainly in the PR that the served effort isn't exposed to the session.",
            "The owner decided on #318 (2026-11-14): a review counts when it was launched on its agent's family"
                .. " with `effort: high` configured, whatever effort the reviewer reports;",
            "Re-run a review only when it was demonstrably launched without `high` configured.",
        }) do
            assert.is_truthy(bullet:find(rule, 1, true), rule)
        end
        for _, name in ipairs(AGENTS) do
            local output = section(wow.readFile(".claude/agents/" .. name .. ".md"), "Output")
            assert.is_truthy(output:find("Don't report an effort level", 1, true), name .. " reports no effort")
        end
        assert.is_truthy(wow.readFile(".github/pull_request_template.md"):find(
            "with the effort as configured (`high`, passed in the Agent call), never a reviewer's own report of it",
            1, true), "the PR template")
    end)

    it("CLAUDE.md's plan-limits rule names the account spending limit as the only sure stop", function()
        local text = wow.readFile("CLAUDE.md")
        local body = text:match("\n## Plan limits\n(.-)\n## ") or ""
        for _, rule in ipairs({
            "- **The gate is 80%.** Past 80% of the weekly plan, long work needs the owner's explicit OK, recorded"
                .. " on the issue.",
            "by 2% of the plan at most. If it can't be sure of that, the owner decides.",
            "- **The reserve:** leave about 3% of the weekly plan for scheduled tasks",
            "- **The only sure stop is the account's spending limit.**",
            "The owner sets that limit; Claude never changes it.",
        }) do
            assert.is_truthy(body:find(rule, 1, true), rule)
        end
    end)

    it("the coordinator reports low usage and model mismatches, and starts every session with model set explicitly and named in the prompt", function()
        local text = wow.readFile(".claude/skills/coordinator/SKILL.md")
        local checkIn = text:match("\n## The 30%-minute check%-in\n(.*)$") or ""
        assert.is_truthy(checkIn:find("- **compare models** for each session you watch: `get_session`'s"
            .. " `configured_model` against `session_context.model` and `external_metadata.last_served_model`",
            1, true), "the model comparison")
        assert.is_truthy(checkIn:find("Include your own session: it must be served by `opus`", 1, true),
            "the coordinator checks its own family")
        assert.is_truthy(checkIn:find("Report any session served by another family to the owner", 1, true),
            "the mismatch report")
        assert.is_truthy(checkIn:find("put what's left in the check-in, even if nothing else changed", 1, true),
            "the low-usage report")
        local start = text:match("%- %*%*Starting a session:%*%*[^\n]*") or ""
        assert.is_truthy(start:find("pass the `model` parameter on every session, set explicitly", 1, true),
            "sessions start with model set explicitly")
        assert.is_truthy(start:find("`sonnet` for a developer, `opus` for security-sensitive and release-workflow"
            .. " changes, specs and hard bugs (with effort `high`)", 1, true), "the families the table gives")
        assert.is_truthy(start:find("The opening prompt names the model", 1, true), "the prompt names the model")
    end)

    -- The after-merge skill sends drivers to AGENTS.md's Reviews section, and
    -- CLAUDE.md keeps Claude's record of who reviewed (#186).
    it("AGENTS.md keeps its Reviews section, with the re-confirmation rule, and CLAUDE.md its review records",
        function()
            local body = wow.readFile("AGENTS.md"):match("\n## Reviews\n(.-)\n## ") or ""
            assert.is_truthy(body:find("- **Changes after an approval:**", 1, true), "Changes after an approval")
            local records = wow.readFile("CLAUDE.md"):match("\n## Review records\n(.*)$") or ""
            assert.is_truthy(records:find("- **Which model reviewed:**", 1, true), "Which model reviewed")
        end)

    it("AGENTS.md starts with a Start here section that links to the detail", function()
        local text = wow.readFile("AGENTS.md")
        local first = text:match("\n## ([^\n]*)")
        assert.are.equal("Start here", first)
        local body = text:match("\n## Start here\n(.-)\n## ") or ""
        for _, words in ipairs({ "`make setup`", "`make check`", "busted spec/<name>_spec.lua",
            "[UI simulator](CONTRIBUTING.md#ui-simulator)", "(CONTRIBUTING.md#local-setup)",
            "(docs/simulated-client.md)", "(docs/ui-simulator.md)", "CONTRIBUTING.md stays the source of truth",
            "**The shape of the code:**" }) do
            assert.is_truthy(body:find(words, 1, true), words)
        end
    end)

    -- Files of game and simulator facts: every bullet has its source.
    for _, path in ipairs({ "docs/forever-facts.md", "docs/ui-simulator.md", "docs/agent-facts.md" }) do
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

    -- The launch-day pass is complete (#197): a rule file never sends a session
    -- to #50 to file an unconfirmed fact; it names the `quality` issue instead.
    -- Each rule is pinned whole (a phrase that also sits elsewhere in the file
    -- would still pass after the rule itself was deleted).
    it("the rule files send unconfirmed game facts to a new quality issue, never to #50", function()
        local function flatten(path) return (wow.readFile(path):gsub("%s+", " ")) end
        for _, path in ipairs({ "AGENTS.md", "CLAUDE.md", "CONTRIBUTING.md",
            ".claude/agents/lua-architect.md", ".claude/agents/lua-tester.md" }) do
            local flat = flatten(path)
            -- The only mentions left say #50 is closed, or name it as the
            -- runbook's source; any other #50 would send a session to a closed issue.
            local allowed = { "(#50, closed; #197)", "Don't reopen #50" }
            if path == "CONTRIBUTING.md" then
                allowed[#allowed + 1] = "is the ordered in-game test pass (from #50)"
            end
            for _, phrase in ipairs(allowed) do
                flat = flat:gsub(phrase:gsub("%p", "%%%0"), "")
            end
            assert.is_falsy(flat:find("#50%f[%D]"), path)
            assert.is_falsy(flat:find("/issues/50%f[%D]"), path)
        end
        local agents = flatten("AGENTS.md")
        for _, rule in ipairs({
            "**Unconfirmed game facts:** the launch-day test pass is complete and its checks worked in game, "
                .. "except four IDs on #207 and the Salvation, Mass Salvation and Revoke checks, removed by Blizzard (#208) (#50, closed; #197). A game fact that can only be checked in game and isn't confirmed yet "
                .. "(spell IDs, role APIs and the like) goes on a new issue labelled `quality`, with the source "
                .. "and how to check it in game. Don't reopen #50.",
            "Document it in the ASSUMPTIONS block, with the new `quality` issue that says what to verify in game, "
                .. "if it isn't confirmed.",
        }) do
            assert.is_truthy(agents:find(rule, 1, true), rule)
        end
        assert.is_truthy(flatten(".claude/agents/lua-architect.md"):find("Anything unconfirmed goes on a new issue "
            .. "labelled `quality`, with its source and how to check it in game (#73, #74, #197).", 1, true))
        assert.is_truthy(flatten(".claude/agents/lua-tester.md"):find("in the ASSUMPTIONS block, and if it is an "
            .. "unconfirmed game fact, with a new `quality` issue that says how to check it in game", 1, true))
    end)

    it("CLAUDE.md sends reviews to the agents and points to every knowledge file and skill", function()
        local text = wow.readFile("CLAUDE.md")
        local shared = wow.readFile("AGENTS.md")
        for _, path in ipairs(DOCS) do assert.is_truthy(shared:find("(" .. path .. ")", 1, true), "AGENTS.md " .. path) end
        for _, name in ipairs(AGENTS) do assert.is_truthy(text:find("`" .. name .. "`", 1, true), name) end
        for _, name in ipairs(SKILLS) do assert.is_truthy(text:find("`" .. name .. "`", 1, true), name) end
        for _, path in ipairs(DOCS) do assert.is_truthy(text:find("(" .. path .. ")", 1, true), path) end
        assert.is_truthy(shared:find("**Keep them current:**", 1, true), "the keep-current rule")
    end)

    -- GitHub deletes merged branches and #115 deletes screenshot branches, so
    -- sessions flag only the ones that outlived their PR, or have none (#119).
    it("AGENTS.md, CLAUDE.md and the coordinator skill flag only stale branches, and keep the never-delete"
        .. " and never-force-push rules", function()
        local claude = wow.readFile("CLAUDE.md")
        local shared = wow.readFile("AGENTS.md")
        local coordinator = wow.readFile(".claude/skills/coordinator/SKILL.md")
        assert.is_falsy(claude:find("any branches for the owner to delete", 1, true), "CLAUDE.md lists merged branches")
        assert.is_falsy(claude:find("branches it names for the owner", 1, true), "CLAUDE.md lists merged branches")
        for name, text in pairs({ ["AGENTS.md"] = shared, coordinator = coordinator }) do
            assert.is_falsy(text:find("any branches for the owner to delete", 1, true), name .. " lists merged branches")
            assert.is_falsy(text:find("branches it names for the owner", 1, true), name .. " lists merged branches")
            assert.is_truthy(text:find("still there after its PR merged or closed, or one with no PR", 1, true),
                name .. " flags a branch that outlived its PR or has none")
        end
        assert.is_truthy(claude:find("\n  2. Send the coordinator one line: `done: #<issue>, PR #<n> merged`, plus any"
            .. " step the owner still has to take (such as applying environment settings or running a workflow) and"
            .. " any stale branch.\n", 1, true), "CLAUDE.md's done line")
        for _, rule in ipairs({
            "\n- **The owner merges.** Never merge, approve or delete branches. Ask before deleting anything. Leave stale"
                .. " branches for the owner, and say which they are.\n",
            "\n- **Force-pushing:** never. Push a rebased branch under a new name and flag the old one for the owner"
                .. " to delete.\n",
        }) do
            assert.is_truthy(shared:find(rule, 1, true), rule)
        end
        assert.is_truthy(coordinator:find("- **Never merges, approves or deletes:** not a PR, a branch, an issue"
            .. " or a comment.", 1, true), "the coordinator's never-delete rule")
        assert.is_truthy(wow.readFile(".claude/skills/after-merge/SKILL.md"):find("Never force-push.", 1, true),
            "after-merge's never-force-push rule")
    end)

    -- The owner's rule (#215): a PR with an open question for the owner isn't
    -- ready. The rule is stated once in CONTRIBUTING.md and referenced elsewhere.
    it("a PR with an open question for the owner is not ready: the rule, its references and the template", function()
        local ready = wow.readFile("CONTRIBUTING.md"):match("\n### Ready for review\n(.-)\n## ") or ""
        assert.is_truthy(ready:find("\n- it has no open question for the maintainer (#215).\n", 1, true), "the bullet")
        assert.is_truthy(ready:find("\n**A pull request with an open question for the maintainer is not ready.**"
            .. " Whoever drives it asks the maintainer first (a session does so through the coordinator) and marks it"
            .. " ready only after the answer is applied. Its description has no \"decisions for the maintainer\""
            .. " section when it is ready. A choice the driver made by following the spec is written plainly as a"
            .. " decision taken, not as a question. If the driver is unsure, that is a question, and the pull request"
            .. " waits. The coordinator doesn't call a pull request ready to merge while a question on it is open.\n",
            1, true), "the rule paragraph")
        assert.is_truthy(wow.readFile("AGENTS.md"):find("\n- **No open question when ready** (#215): a PR with an"
            .. " open question for the owner is not ready. Ask first, and mark it ready only after the answer is"
            .. " applied (CONTRIBUTING.md's \"Ready for review\").\n", 1, true), "AGENTS.md's reference")
        assert.is_truthy(wow.readFile("CLAUDE.md"):find("\n  - you need the owner: a question (one you ask in your"
            .. " own session too), a decision or a blocker. Ask before you mark the PR ready: it waits for the"
            .. " answer (#215);\n", 1, true), "CLAUDE.md's notice rule")
        assert.is_truthy(wow.readFile(".github/pull_request_template.md"):find("\n- [ ] No open question for the"
            .. " owner: this description has no \"decisions for the owner\" section, and choices made by following the"
            .. " spec are stated as decisions taken\n", 1, true), "the PR template")
        local coordinator = wow.readFile(".claude/skills/coordinator/SKILL.md")
        local announced = coordinator:match("\n## A PR announced ready\n(.-)\n## ") or ""
        assert.is_truthy(announced:find("\n3. Check there is no open owner question on it: none in its description,"
            .. " and none in its session's transcript that the owner hasn't answered. If there is one, it isn't ready"
            .. " to merge (CONTRIBUTING.md's \"Ready for review\", #215): tell its driver to wait for the answer, and"
            .. " put the question in the report.\n", 1, true), "the coordinator's ready steps")
        assert.is_truthy(coordinator:find("\n- **Questions come first.** Put every question for the owner at the"
            .. " top of the report, one per line, before any list of PRs (#215).\n", 1, true), "questions first")
    end)

    -- The owner's standing rule (#172): the coordinator spots merges itself and
    -- closes out finished sessions politely, archiving only after their summary.
    it("the coordinator skill keeps the close-out rule for finished sessions", function()
        local coordinator = wow.readFile(".claude/skills/coordinator/SKILL.md")
        for _, rule in ipairs({
            "\n- read each tracked PR's state on GitHub, and run \"After the owner merges a PR\" for any that merged"
                .. " or closed;\n",
            "\n- archive every finished session whose closing summary is in;\n",
            "\n2. **Tell the merged PR's session at once, politely** (the owner's standing rule, #172).",
            "\n3. **Archive that session only after its closing summary,** once it's idle. Read its transcript"
                .. " first, not just its status. Never archive a session that is working or waiting on the owner.\n",
        }) do
            assert.is_truthy(coordinator:find(rule, 1, true), rule)
        end
    end)
end)
