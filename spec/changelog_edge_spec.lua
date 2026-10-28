-- Spec: #51, #76
-- Review tests for the changelog checker: mutation killers, the check and
-- the release-notes sed agreeing line by line, and seeded fuzzing.
local wow = require("spec.support.wow")
local random = require("spec.support.random")
local Changelog = require("spec.support.changelog")

local function changelog(...)
    return "# Changelog\n\n" .. table.concat({ ... }, "\n") .. "\n"
end

local function untagged(text) return Changelog.UntaggedEntries(text, "### Unreleased") end

-- Runs release-notes.sh over the given lines (as a "## 9.9.9" section) and
-- returns the output lines without the heading.
local function releaseNotes(lines)
    local dir = os.tmpname()
    os.remove(dir)
    os.execute('mkdir -p "' .. dir .. '"')
    local file = io.open(dir .. "/CHANGELOG.md", "wb")
    file:write("# Changelog\n\n## 9.9.9\n" .. table.concat(lines, "\n") .. "\n\n## 1.0.0\n")
    file:close()
    local p = io.popen('cd "' .. wow.ROOT .. '" && ./scripts/release-notes.sh "' .. dir .. '/CHANGELOG.md" "'
        .. dir .. '/NOTES.md" >/dev/null 2>&1; echo $?')
    local code = tonumber(p:read("*a"))
    p:close()
    local notesFile = io.open(dir .. "/NOTES.md", "rb")
    local notes = notesFile and notesFile:read("*a") or ""
    if notesFile then notesFile:close() end
    os.execute('rm -rf "' .. dir .. '"')
    assert.are.equal(0, code)
    local out = {}
    for line in notes:gmatch("([^\n]*)\n") do out[#out + 1] = line end
    table.remove(out, 1) -- the heading
    table.remove(out) -- the blank line before the next section
    return out
end

describe("Changelog checker (review)", function()
    describe("white", function()
        it("splits lines, keeping the last one without a newline and dropping CRs", function()
            assert.are.same({ "a", "b" }, Changelog.Lines("a\r\nb"))
            assert.are.same({ "a", "" }, Changelog.Lines("a\n"))
        end)

        it("checks an entry on a last line with no newline", function()
            assert.are.equal(1, #untagged("### Unreleased\n\n- No newline at the end."))
        end)

        it("finds a heading written with trailing spaces", function()
            assert.are.equal(1, #untagged(changelog("### Unreleased  ", "", "- Untagged.")))
            assert.are.equal(2, Changelog.CountHeading(changelog("### Unreleased", "- a (#1)", "### Unreleased  ",
                "- b (#2)"), "### Unreleased"))
        end)

        it("ends a release's section at an Unreleased heading", function()
            assert.are.same({ "- a" }, (Changelog.Section(changelog("## 1.7.0", "- a", "### Unreleased  ", "- b"),
                "## 1.7.0")))
        end)

        it("returns nil for a missing section, and only matches heading lines", function()
            assert.is_nil(Changelog.Section(changelog("## 1.6.0", "- x"), "### Unreleased"))
            assert.is_nil(Changelog.Section("- x\n- y", "- x"))
        end)

        it("keeps * and + sub-bullets, and their wrapped lines, out of the entry", function()
            assert.are.same({}, untagged(changelog("### Unreleased", "", "- Main. (#1)", "  * detail", "  + more")))
            assert.are.same({}, untagged(changelog("### Unreleased", "", "- Main. (#1)", "  - a detail",
                "    that wraps")))
        end)

        it("joins wrapped lines with one space, without their indentation", function()
            local found = untagged(changelog("### Unreleased", "", "- Wraps", "    here."))
            assert.are.equal("line 5: ...- Wraps here.", Changelog.Describe(found))
        end)

        it("doesn't take a thematic break or bold text for an entry", function()
            assert.are.same({}, untagged(changelog("### Unreleased", "", "- One. (#1)", "", "---", "", "**Bold**")))
        end)

        it("shows the last 60 characters of a long entry", function()
            local entry = "- " .. ("x"):rep(100) .. " ends here"
            local found = untagged(changelog("### Unreleased", "", entry))
            assert.are.equal("line 5: ..." .. entry:sub(-60), Changelog.Describe(found))
        end)

        it("compares versions of different lengths", function()
            assert.is_true(Changelog.IsLater("1.6.1", "1.6"))
            assert.is_false(Changelog.IsLater("1.6.0", "1.6"))
            assert.is_false(Changelog.IsLater("1.6", "1.6.0"))
            assert.is_true(Changelog.IsLater("2", "1.99.99"))
        end)
    end)

    describe("black: the release notes keep every malformed tag", function()
        it("leaves each line the check rejects as written", function()
            local lines = {
                "- No tag.", "- (#27) Tag first, not last.", "- Hash after. (#27#)", "- Empty part. (#27, )",
                "- Missing hash. (#27, 52)", "- Space inside. (# 27)", "- No comma space. (#27,#52)",
                "- No comma. (#27 #52)", "- Zero. (#0)", "- Leading zero. (#027)", "- Empty. ()",
                "- Not an issue. (see above)", "- No space before it.(#27)", "- Mid (#27) line.",
            }
            assert.are.same(lines, releaseNotes(lines))
        end)

        it("writes LF notes from a CRLF changelog", function()
            local out = releaseNotes({ "- One. (#1)\r", "- Kept.\r" })
            assert.are.same({ "- One.", "- Kept." }, { out[1], out[2] })
        end)
    end)

    -- Defects found in review: each of these passes the check today.
    describe("black: untagged entries in unusual Markdown are reported", function()
        it("reports untagged entries under an indented or unspaced Unreleased heading", function()
            local text = changelog(" ### Unreleased", "", "- Untagged.", "", "## 1.6.0")
            assert.is_true(#untagged(text) > 0 or Changelog.FirstSectionHeading(text) ~= "## 1.6.0")
        end)

        it("reports an indented top-level bullet, a numbered entry and a tab bullet", function()
            assert.are.equal(3, #untagged(changelog("### Unreleased", "", " - One space in.", "", "1. Numbered.",
                "", "-\tTab.")))
        end)

        it("won't accept a tag the release notes can't take off (wrapped over two lines)", function()
            local text = changelog("### Unreleased", "", "- A wrapped entry (#27,", "  #52)")
            assert.are.equal(1, #untagged(text))
        end)
    end)

    describe("differential: TagIssues/WithoutTag agree with release-notes.sh", function()
        local starts = { "- Entry.", "- ", "", "-", "* Star", "  - sub", "## not first", "x" }
        local seps = { " ", "", "  ", "\t" }
        local items = { "#1", "#27", "#52", "#0", "#027", "# 5", "#", "27", "#12a", "#99", "#1#" }
        local joins = { ", ", ",", " ", ", ,", ",  " }
        local ends = { "", " ", "  ", "\t", "x", ")", " (x)" }

        local function generate(n, seed)
            random.seed(seed)
            local lines = {}
            for _ = 1, n do
                local parts = {}
                local used = {}
                for _ = 1, random.random(1, 3) do
                    local item = items[random.random(#items)]
                    -- Repeated issues are their own test below.
                    if not used[item] then parts[#parts + 1], used[item] = item, true end
                end
                local inside = table.concat(parts, joins[random.random(#joins)])
                local open = random.random(10) > 1 and "(" or ""
                local close = random.random(10) > 1 and ")" or ""
                local line = starts[random.random(#starts)] .. seps[random.random(#seps)] .. open .. inside .. close
                    .. ends[random.random(#ends)]
                if not line:match("^## ") then lines[#lines + 1] = line end
            end
            return lines
        end

        for _, seed in ipairs({ 1, 51, 2026 }) do
            it("over 2000 generated lines (seed " .. seed .. ")", function()
                local lines = generate(2000, seed)
                local notes = releaseNotes(lines)
                local differ = {}
                for i, line in ipairs(lines) do
                    if Changelog.WithoutTag(line) ~= notes[i] then
                        differ[#differ + 1] = ("%q -> lua %q, sed %q"):format(line, Changelog.WithoutTag(line),
                            tostring(notes[i]))
                    end
                end
                assert.are.same({}, differ, table.concat(differ, "\n", 1, math.min(#differ, 10)))
            end)
        end

        it("on repeated issues", function()
            local lines = { "- Dup. (#27, #27)" }
            assert.are.same({ Changelog.WithoutTag(lines[1]) }, releaseNotes(lines))
        end)
    end)

    describe("red: seeded random text never errors", function()
        local alphabet = { "-", "*", "+", " ", "  ", "\t", "\n", "\r\n", "\r", "#", "## ", "### Unreleased", "(",
            ")", "(#", "#27", ", ", "1", "0", "x", "\0", "\255", "%", "%s", ".", "[", "]", "^", "$" }

        local function junk(len)
            local out = {}
            for i = 1, len do out[i] = alphabet[random.random(#alphabet)] end
            return table.concat(out)
        end

        for _, seed in ipairs({ 7, 51, 1337 }) do
            it("for every helper (seed " .. seed .. ")", function()
                random.seed(seed)
                for _ = 1, 500 do
                    local text = junk(random.random(0, 200))
                    local ok, err = pcall(function()
                        local issues = Changelog.TagIssues(text)
                        assert(issues == nil or type(issues) == "table")
                        assert(type(Changelog.WithoutTag(text)) == "string")
                        assert(type(Changelog.CountHeading(text, "### Unreleased")) == "number")
                        assert(type(Changelog.Lines(text)) == "table")
                        local first = Changelog.FirstSectionHeading(text)
                        assert(first == nil or type(first) == "string")
                        local lines = Changelog.Section(text, "### Unreleased")
                        assert(lines == nil or type(lines) == "table")
                        assert(type(Changelog.Entries(Changelog.Lines(text))) == "table")
                        local found = Changelog.UntaggedEntries(text, "### Unreleased")
                        assert(type(Changelog.Describe(found)) == "string")
                        for _, entry in ipairs(found) do assert(entry.line >= 1) end
                        assert(type(Changelog.IsLater(text, text:reverse())) == "boolean")
                        assert(Changelog.IsLater(text, text) == false)
                    end)
                    assert.is_true(ok, ("%q: %s"):format(text, tostring(err)))
                end
            end)
        end

        it("handles a very long wrapped entry quickly", function()
            local lines = { "### Unreleased", "", "- Start" }
            for i = 1, 20000 do lines[#lines + 1] = "  wrapped line " .. i end
            local started = os.clock()
            assert.are.equal(1, #untagged(table.concat(lines, "\n")))
            assert.is_true(os.clock() - started < 5, "took " .. (os.clock() - started) .. "s")
        end)
    end)
end)
