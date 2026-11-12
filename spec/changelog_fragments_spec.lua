-- Spec: #261
-- Changelog notes as one file per pull request (changes/<issue>.md), so two
-- PRs never edit the same lines, gathered into the release's section by the
-- release PR (scripts/changelog-gather.lua). The workflow steps that run the
-- release-time check are in spec/repo_spec.lua.
local wow = require("spec.support.wow")
local Changelog = require("spec.support.changelog")

local ROOT = wow.ROOT == "" and "./" or wow.ROOT
local Gather = assert(loadfile(ROOT .. "scripts/changelog-gather.lua"))("--module")

local function sh(command)
    local pipe = io.popen("cd '" .. ROOT .. "' && { " .. command .. "\n} 2>&1; echo rc=$?")
    local out = pipe:read("*a")
    pipe:close()
    return out:gsub("rc=%d+\n$", ""), tonumber(out:match("rc=(%d+)\n$"))
end

local function tempDir()
    local dir = io.popen("mktemp -d"):read("*l")
    assert(dir and dir ~= "", "mktemp -d failed")
    return dir
end

local function write(path, text)
    local file = assert(io.open(path, "wb"))
    file:write(text)
    file:close()
end

local function read(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local text = file:read("*a")
    file:close()
    return text
end

local function changelog(...)
    return "# Changelog\n\n" .. table.concat({ ... }, "\n") .. "\n"
end

-- The old release step: rename the Unreleased heading to the version.
local function oldProcess(text, version)
    return (text:gsub("### Unreleased", "## " .. version, 1))
end

-- Runs the gather script's Main on a folder, collecting what it prints.
local function main(argv)
    local out, err = {}, {}
    local code = Gather.Main(argv, function(line) out[#out + 1] = line end, function(line) err[#err + 1] = line end)
    return code, table.concat(out, "\n"), table.concat(err, "\n")
end

-- A changelog and a changes/ folder in a temporary directory.
local function workspace(text, fragments)
    local dir = tempDir()
    write(dir .. "/CHANGELOG.md", text)
    os.execute("mkdir '" .. dir .. "/changes'")
    for name, body in pairs(fragments or {}) do write(dir .. "/changes/" .. name, body) end
    return dir
end

describe("Changelog fragments (#261)", function()
    describe("white: gathering at release time", function()
        it("gives the same section the old rename would, for leftover Unreleased bullets plus fragments", function()
            local old = oldProcess(changelog("### Unreleased", "", "- **One:** first. (#5)", "- **Two:** second. (#9)",
                "", "## 1.0.1", "", "- Old. (#1)"), "1.1.0")
            local gathered = Changelog.Gather(changelog("### Unreleased", "", "- **One:** first. (#5)", "",
                "## 1.0.1", "", "- Old. (#1)"), "1.1.0", { { name = "9.md", text = "- **Two:** second. (#9)\n" } })
            assert.are.equal(old, gathered)
        end)

        it("gives the same section with no Unreleased heading left, all from fragments", function()
            local old = oldProcess(changelog("### Unreleased", "", "- A. (#5)", "- B. (#9)", "", "## 1.0.1", "",
                "- Old. (#1)"), "1.1.0")
            local gathered = Changelog.Gather(changelog("## 1.0.1", "", "- Old. (#1)"), "1.1.0",
                { { name = "9.md", text = "- B. (#9)" }, { name = "5.md", text = "- A. (#5)\n" } })
            assert.are.equal(old, gathered)
        end)

        it("puts leftover bullets first as written, then fragments by issue number, then by name", function()
            local gathered = Changelog.Gather(changelog("### Unreleased", "", "- Left. (#300)", "", "## 1.0.0", "",
                "- x (#1)"), "1.0.1", {
                { name = "10.md", text = "- Ten. (#10)" },
                { name = "9-b.md", text = "- Nine b. (#9)" },
                { name = "9.md", text = "- Nine. (#9)" },
                { name = "9-a.md", text = "- Nine a. (#9)" },
            })
            local lines = Changelog.Section(gathered, "## 1.0.1")
            assert.are.same({ "", "- Left. (#300)", "- Nine a. (#9)", "- Nine b. (#9)", "- Nine. (#9)", "- Ten. (#10)", "" },
                lines)
        end)

        it("keeps a fragment's wrapped lines and sub-bullets, and drops Windows line endings", function()
            local gathered = Changelog.Gather(changelog("## 1.0.0", "", "- x (#1)"), "1.0.1",
                { { name = "7.md", text = "- Wraps\r\n  onto the end. (#7)\r\n  - a detail\r\n\r\n" } })
            assert.are.same({ "", "- Wraps", "  onto the end. (#7)", "  - a detail", "" },
                Changelog.Section(gathered, "## 1.0.1"))
            assert.is_nil(gathered:find("\r", 1, true))
        end)

        it("leaves the heading, the older releases and nothing else changed", function()
            local text = changelog("### Unreleased", "", "- New. (#3)", "", "## 1.0.0", "", "- Old. (#1)", "",
                "## 0.9.0", "", "- Older. (#2)")
            local gathered = Changelog.Gather(text, "1.1.0", {})
            assert.are.equal(oldProcess(text, "1.1.0"), gathered)
        end)

        it("gathers the real changelog and fragments as the old rename plus each fragment", function()
            local text = wow.readFile("CHANGELOG.md")
            local fragments = Gather.ReadFragments(ROOT .. "changes")
            local version = "99.0.0"
            local gathered, problem = Changelog.Gather(text, version, fragments)
            assert.is_truthy(gathered, problem)
            local expected = Changelog.Section(oldProcess(text, version), "## " .. version)
            if not expected then
                -- No Unreleased heading: the old process had an empty one.
                expected = { "" }
            else
                while expected[#expected] == "" do table.remove(expected) end
            end
            for _, fragment in ipairs(Changelog.SortFragments(fragments)) do
                for _, line in ipairs(Changelog.Lines(fragment.text)) do
                    if line:match("%S") then expected[#expected + 1] = line end
                end
            end
            expected[#expected + 1] = ""
            assert.are.same(expected, Changelog.Section(gathered, "## " .. version))
            assert.are.equal(0, Changelog.CountHeading(gathered, "### Unreleased"))
        end)

        it("writes the changelog and deletes every fragment (the script)", function()
            local dir = workspace(changelog("### Unreleased", "", "- Left. (#4)", "", "## 1.0.0", "", "- x (#1)"),
                { ["5.md"] = "- Five. (#5)\n", ["6-two.md"] = "- Six. (#6)\n" })
            local code, out, err = main({ "1.1.0", dir .. "/CHANGELOG.md", dir .. "/changes" })
            local text = read(dir .. "/CHANGELOG.md")
            local left = sh("ls -A '" .. dir .. "/changes' '" .. dir .. "'")
            os.execute("rm -rf '" .. dir .. "'")
            assert.are.equal(0, code, err)
            assert.are.equal(changelog("## 1.1.0", "", "- Left. (#4)", "- Five. (#5)", "- Six. (#6)", "", "## 1.0.0", "",
                "- x (#1)"), text)
            assert.is_truthy(out:find("gathered and deleted changes/5.md", 1, true), out)
            assert.is_nil(left:find("%.md\n.*%.md\n.*%.md"), "fragments left: " .. left)
            assert.is_nil(left:find("gather", 1, true), "temporary file left: " .. left)
        end)

        it("changes nothing on a dry run, and shows the section and the files it would delete", function()
            local before = changelog("## 1.0.0", "", "- x (#1)")
            local dir = workspace(before, { ["5.md"] = "- Five. (#5)\n" })
            local code, out = main({ "--dry-run", "1.1.0", dir .. "/CHANGELOG.md", dir .. "/changes" })
            local text, kept = read(dir .. "/CHANGELOG.md"), read(dir .. "/changes/5.md")
            os.execute("rm -rf '" .. dir .. "'")
            assert.are.equal(0, code)
            assert.are.equal(before, text)
            assert.are.equal("- Five. (#5)\n", kept)
            assert.is_truthy(out:find("## 1.1.0\n\n- Five. (#5)\n", 1, true), out)
            assert.is_truthy(out:find("would delete changes/5.md", 1, true), out)
        end)

        it("runs from the command line with the toolchain's Lua, as make changelog does", function()
            local i = 0
            while arg and arg[i - 1] do i = i - 1 end
            local lua = arg and arg[i]
            assert.is_truthy(lua and lua:match("lua"), "couldn't find the Lua running the tests: " .. tostring(lua))
            local dir = workspace(changelog("## 1.0.0", "", "- x (#1)"), { ["5.md"] = "- Five. (#5)\n" })
            local out, code = sh("'" .. lua .. "' scripts/changelog-gather.lua 1.1.0 '" .. dir .. "/CHANGELOG.md' '"
                .. dir .. "/changes'")
            local bad, badCode = sh("'" .. lua .. "' scripts/changelog-gather.lua")
            local text = read(dir .. "/CHANGELOG.md")
            os.execute("rm -rf '" .. dir .. "'")
            assert.are.equal(0, code, out)
            assert.is_truthy(text:find("## 1.1.0\n\n- Five. (#5)\n", 1, true), text)
            assert.are.equal(2, badCode, bad)
            assert.is_truthy(bad:find("usage:", 1, true), bad)
        end)
    end)

    describe("white: release notes contain every fragment", function()
        it("once gathered, the notes hold each fragment's bullet without its tag", function()
            local fragments = {
                ["12.md"] = "- **Twelve:** a change. (#12)\n",
                ["30-part2.md"] = "- **Thirty:** wraps\n  onto two lines. (#30, #31)\n",
            }
            local dir = workspace(changelog("### Unreleased", "", "- **Left:** over. (#2)", "", "## 1.0.0", "", "- x (#1)"),
                fragments)
            local code, _, err = main({ "1.1.0", dir .. "/CHANGELOG.md", dir .. "/changes" })
            local out, notesCode = sh("./scripts/release-notes.sh --release '" .. dir .. "/CHANGELOG.md' '" .. dir
                .. "/NOTES.md' '" .. dir .. "/changes'")
            local notes = read(dir .. "/NOTES.md") or ""
            os.execute("rm -rf '" .. dir .. "'")
            assert.are.equal(0, code, err)
            assert.are.equal(0, notesCode, out)
            assert.are.equal("## 1.1.0\n\n- **Left:** over.\n- **Twelve:** a change.\n- **Thirty:** wraps\n  onto two lines.\n\n",
                notes)
        end)

        it("the real fragments all reach the notes once gathered", function()
            local dir = tempDir()
            os.execute("cp '" .. ROOT .. "CHANGELOG.md' '" .. dir .. "/' && cp -R '" .. ROOT .. "changes' '" .. dir
                .. "/changes' 2>/dev/null")
            local fragments = Gather.ReadFragments(dir .. "/changes")
            local code, _, err = main({ "99.0.0", dir .. "/CHANGELOG.md", dir .. "/changes" })
            local out, notesCode = sh("./scripts/release-notes.sh --release '" .. dir .. "/CHANGELOG.md' '" .. dir
                .. "/NOTES.md' '" .. dir .. "/changes'")
            local notes = read(dir .. "/NOTES.md") or ""
            os.execute("rm -rf '" .. dir .. "'")
            assert.are.equal(0, code, err)
            assert.are.equal(0, notesCode, out)
            for _, fragment in ipairs(fragments) do
                local entry = Changelog.Entries(Changelog.Lines(fragment.text))[1]
                local first = Changelog.WithoutTag(Changelog.Lines(fragment.text)[1])
                assert.is_truthy(entry and notes:find(first, 1, true), "missing from the notes: " .. fragment.name)
            end
        end)
    end)

    describe("white: two pull requests each adding a fragment", function()
        it("merge in either order with no conflict in any changelog file", function()
            local dir = tempDir()
            local script = [[
                set -e
                cd "$1"
                git init -q -b main .
                git config user.email t@example.invalid
                git config user.name t
                cp "$2/CHANGELOG.md" .
                mkdir -p changes
                printf -- '- **Base:** one. (#100)\n' > changes/100.md
                git add -A && git commit -qm base
                git checkout -qb a && printf -- '- **A:** a. (#247)\n' > changes/247.md && git add -A && git commit -qm a
                git checkout -q main && git checkout -qb b && printf -- '- **B:** b. (#248)\n' > changes/248.md \
                    && git add -A && git commit -qm b
                for first in a b; do
                    second=$([ $first = a ] && echo b || echo a)
                    git checkout -q main && git checkout -qB try-$first main
                    git merge -q --no-edit $first
                    git merge -q --no-edit $second || { echo "conflict merging $second after $first"; exit 1; }
                    ls changes | tr '\n' ' '; echo
                    git diff --quiet main -- CHANGELOG.md || { echo "CHANGELOG.md changed"; exit 1; }
                done
            ]]
            local root = ROOT:sub(1, 1) == "/" and ROOT or (io.popen("pwd"):read("*l") .. "/" .. ROOT)
            write(dir .. "/merge.sh", script)
            local out, code = sh("mkdir '" .. dir .. "/repo' && bash '" .. dir .. "/merge.sh' '" .. dir .. "/repo' '"
                .. root .. "'")
            os.execute("rm -rf '" .. dir .. "'")
            assert.are.equal(0, code, out)
            local _, merges = out:gsub("100%.md 247%.md 248%.md", "")
            assert.are.equal(2, merges, out)
        end)
    end)

    describe("black: a bad fragment fails with a clear message", function()
        local cases = {
            { "no tag", "5.md", "- **Five:** no tag.\n", "must end with its issue" },
            { "a tag that isn't at the end", "5.md", "- **Five:** (#5) not at the end.\n", "must end with its issue" },
            { "a tag without its own issue", "5.md", "- **Five:** wrong. (#6)\n", "must include #5" },
            { "an empty file", "5.md", "", "empty" },
            { "only blank lines", "5.md", "\n  \n\r\n", "empty" },
            { "not a bullet", "5.md", "Five. (#5)\n", "must start with a bullet" },
            { "a star bullet", "5.md", "* Five. (#5)\n", "must start with a bullet" },
            { "two bullets", "5.md", "- One. (#5)\n- Two. (#5)\n", "holds 2 bullets" },
            { "a blank line inside", "5.md", "- One. (#5)\n\n- Two. (#5)\n", "blank line" },
            { "a heading", "5.md", "- One. (#5)\n## 9.9.9\n", "no headings" },
            { "a .txt file", "5.txt", "- Five. (#5)\n", "not a fragment" },
            { "no issue in the name", "notes.md", "- Five. (#5)\n", "not a fragment" },
            { "a zero issue", "0.md", "- Zero. (#0)\n", "not a fragment" },
            { "a hidden file", ".gitkeep", "", "not a fragment" },
            { "a capital letter in the word", "5-Part2.md", "- Five. (#5)\n", "not a fragment" },
            { "a folder", "5.md", nil, "can't be read" },
        }
        for _, case in ipairs(cases) do
            it(case[1], function()
                local problem = Changelog.FragmentProblem(case[2], case[3])
                assert.is_truthy(problem, case[1] .. " passed")
                assert.is_truthy(problem:find("changes/" .. case[2], 1, true), problem)
                assert.is_truthy(problem:find(case[4], 1, true), problem)
            end)
        end

        it("accepts a good fragment, and a second one on the same issue", function()
            assert.is_nil(Changelog.FragmentProblem("261.md", "- **Notes:** as files. (#261)\n"))
            assert.is_nil(Changelog.FragmentProblem("256-part2.md", "- **More:** done. (#70, #256)"))
            assert.is_nil(Changelog.FragmentProblem("7.md", "\n- Wraps\n  here. (#7)\n  - detail\n\n"))
            -- As in CHANGELOG.md, a sub-bullet's text isn't the entry's: the tag goes on the entry.
            assert.is_truthy(Changelog.FragmentProblem("7.md", "- Main.\n  - detail (#7)\n"))
        end)

        it("the gather script refuses and changes nothing when any fragment is bad, naming each", function()
            local before = changelog("### Unreleased", "", "- Left. (#4)", "", "## 1.0.0", "", "- x (#1)")
            local dir = workspace(before, { ["5.md"] = "- Good. (#5)\n", ["6.md"] = "", ["x.txt"] = "hi" })
            local code, _, err = main({ "1.1.0", dir .. "/CHANGELOG.md", dir .. "/changes" })
            local text = read(dir .. "/CHANGELOG.md")
            local left = sh("ls '" .. dir .. "/changes'")
            os.execute("rm -rf '" .. dir .. "'")
            assert.are.equal(1, code)
            assert.is_truthy(err:find("changes/6.md: empty", 1, true), err)
            assert.is_truthy(err:find("changes/x.txt: not a fragment", 1, true), err)
            assert.are.equal(before, text)
            assert.are.equal("5.md\n6.md\nx.txt\n", left)
        end)

        it("the gather script refuses a version that isn't new, a bad version, or nothing to release", function()
            local text = changelog("## 1.0.0", "", "- x (#1)")
            local _, why = Changelog.Gather(text, "1.0.0", { { name = "5.md", text = "- Five. (#5)" } })
            assert.is_truthy(why and why:find("must come after the newest release", 1, true), why)
            _, why = Changelog.Gather(text, "v1.1", { { name = "5.md", text = "- Five. (#5)" } })
            assert.is_truthy(why and why:find("must look like 1.2.3", 1, true), why)
            _, why = Changelog.Gather(text, "1.1.0", {})
            assert.is_truthy(why and why:find("nothing to release", 1, true), why)
            _, why = Changelog.Gather(changelog("### Unreleased", "- a (#1)", "### Unreleased", "- b (#2)"), "1.1.0", {})
            assert.is_truthy(why and why:find("more than one ### Unreleased", 1, true), why)
            _, why = Changelog.Gather(nil, "1.1.0", { { name = "5.md", text = "- Five. (#5)" } })
            assert.is_truthy(why and why:find("empty", 1, true), why)
        end)

        it("a folder inside changes/ is reported, not read", function()
            local dir = workspace(changelog("## 1.0.0", "", "- x (#1)"))
            os.execute("mkdir '" .. dir .. "/changes/5.md'")
            local fragments = Gather.ReadFragments(dir .. "/changes")
            os.execute("rm -rf '" .. dir .. "'")
            assert.are.equal(1, #fragments)
            assert.is_truthy(Changelog.FragmentProblem(fragments[1].name, fragments[1].text):find("can't be read", 1, true))
        end)

        -- What make check enforces on the repository itself.
        it("every file in the real changes/ is a good fragment", function()
            local problems = {}
            for _, fragment in ipairs(Gather.ReadFragments(ROOT .. "changes")) do
                problems[#problems + 1] = Changelog.FragmentProblem(fragment.name, fragment.text)
            end
            assert.are.same({}, problems, table.concat(problems, "\n"))
        end)
    end)

    describe("black: the release notes refuse to leave a note behind", function()
        local function notes(text, fragments, release)
            local dir = workspace(text, fragments)
            local out, code = sh("./scripts/release-notes.sh " .. (release and "--release " or "") .. "'" .. dir
                .. "/CHANGELOG.md' '" .. dir .. "/NOTES.md' '" .. dir .. "/changes'")
            local written = read(dir .. "/NOTES.md")
            os.execute("rm -rf '" .. dir .. "'")
            return out, code, written
        end

        it("fails with --release while a fragment waits, naming it, and writes nothing", function()
            local out, code, written = notes(changelog("## 1.1.0", "", "- x (#1)"), { ["5.md"] = "- Five. (#5)\n" }, true)
            assert.are_not.equal(0, code)
            assert.is_truthy(out:find("make changelog", 1, true), out)
            assert.is_truthy(out:find("  5.md", 1, true), out)
            assert.is_nil(written)
        end)

        it("fails with --release while a bullet waits under ### Unreleased", function()
            local out, code = notes(changelog("### Unreleased", "", "- New. (#2)", "", "## 1.1.0", "", "- x (#1)"), {}, true)
            assert.are_not.equal(0, code)
            assert.is_truthy(out:find("### Unreleased", 1, true), out)
        end)

        it("passes with --release once everything is gathered, and without it between releases", function()
            local _, code, written = notes(changelog("## 1.1.0", "", "- x (#1)"), {}, true)
            assert.are.equal(0, code)
            assert.are.equal("## 1.1.0\n\n- x\n", written)
            _, code = notes(changelog("## 1.1.0", "", "- x (#1)"), { ["5.md"] = "- Five. (#5)\n" }, false)
            assert.are.equal(0, code)
        end)
    end)
end)
