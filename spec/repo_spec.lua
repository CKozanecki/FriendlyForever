-- Spec: #77, #80, #82
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
        -- loaded by the game without being listed in the TOC).
        local shipped = { ["FriendlyForever.toc"] = true, ["README.md"] = true,
            ["CHANGELOG.md"] = true, ["LICENSE"] = true, ["Bindings.xml"] = true }
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
    -- The comparison and the line that stops the job when it fails.
    local compare = text:match('(%[%[ "v%$toc" == "%$GITHUB_REF_NAME" %]%] \\\n[^\n]*exit 1; })')

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
        local ok = os.execute('cd "' .. dir .. '" && bash check.sh')
        os.execute('rm -rf "' .. dir .. '"')
        return ok == true or ok == 0
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

    it("accepts the tag for the TOC's own version", function()
        local toc = wow.readFile("FriendlyForever.toc")
        assert.is_true(accepts(toc, "v" .. wow.parseToc().Version))
        assert.is_true(accepts("## Version: 0.8.0\n", "v0.8.0"))
    end)

    it("rejects a tag that is not the TOC's version, or a TOC with no version", function()
        assert.is_false(accepts("## Version: 0.8.0\n", "v1.6.0"))
        assert.is_false(accepts("## Version: 0.8.0\n", "v0.8.0-beta"))
        assert.is_false(accepts("## Version: 0.8.0\n", "0.8.0"))
        assert.is_false(accepts("## Title: Friendly Forever\n", "v0.8.0"))
    end)

    it("still accepts the right tag when the TOC has Windows line endings", function()
        assert.is_true(accepts("## Version: 0.8.0\r\n## Title: x\r\n", "v0.8.0"))
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
    -- Wording that has the reader make the release: an imperative verb (not
    -- the workflow's "creates" or "makes") before "a" or "the" release, "you"
    -- or "the maintainer" as the one making it, or GitHub's own button and
    -- page for making one.
    local MANUAL = { "generate release notes", "releases/new" }
    for _, forms in ipairs({ { "create", "creates" }, { "make", "makes" }, { "publish", "publishes" },
        { "draft", "drafts" } }) do
        local verb, says = forms[1], forms[2]
        for _, article in ipairs({ "an?", "the" }) do
            MANUAL[#MANUAL + 1] = verb .. " " .. article .. " [%w ]-release"
        end
        MANUAL[#MANUAL + 1] = "you " .. verb
        MANUAL[#MANUAL + 1] = "maintainer " .. says
    end

    -- Each manual-release instruction in text, as the words that matched.
    -- Case, markdown emphasis and line breaks (LF or CRLF) don't hide one.
    local function manualReleaseSteps(text)
        local flat = text:lower():gsub("[%*_`]", ""):gsub("%s+", " ")
        local found = {}
        for _, pattern in ipairs(MANUAL) do
            local match = flat:match(pattern)
            if match then found[#found + 1] = match end
        end
        return found
    end

    describe("finder", function()
        it("finds the old instructions to create the release by hand", function()
            local old = "- **Releases:** after tagging, the maintainer creates a GitHub release for the tag with "
                .. "**Generate release notes**, which lists the pull requests and the issues they closed.\n"
                .. "2. After it merges, tag the merge commit and push the tag. Then create a GitHub release "
                .. "for the tag with **Generate release notes**.\n"
            assert.are.same({ "generate release notes", "create a github release", "maintainer creates" },
                manualReleaseSteps(old))
        end)

        it("finds a manual step however it is worded", function()
            for _, text in ipairs({
                "Then create the GitHub release.",
                "Create a release for the tag.",
                "Create an annotated GitHub release.",
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
                .. "Run `make release-notes` to preview the notes."))
        end)
    end)

    describe("the real docs", function()
        for _, path in ipairs({ "CONTRIBUTING.md", "README.md" }) do
            it(path .. " never tells the maintainer to create a GitHub release for the tag", function()
                assert.are.same({}, manualReleaseSteps(wow.readFile(path)))
            end)
        end

        it("CONTRIBUTING.md says the workflow creates the release, with the changelog as its notes", function()
            local flat = wow.readFile("CONTRIBUTING.md"):gsub("%s+", " ")
            assert.is_truthy(flat:find("the Release workflow creates the GitHub release for each tag", 1, true))
            assert.is_truthy(flat:find("Its notes are that version's changelog section", 1, true))
            assert.is_truthy(flat:find("creates the GitHub release for the tag, with the same notes", 1, true))
            assert.is_truthy(flat:find("Once the job is green, there's nothing left to do.", 1, true))
        end)
    end)
end)
