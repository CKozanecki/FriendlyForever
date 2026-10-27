-- Spec: #51
-- Changelog entries trace to the issues holding their specs: each ends with
-- "(#27)" or "(#27, #52)". The checker is tested on made-up changelogs, then
-- run on the real one.
local wow = require("spec.support.wow")
local Changelog = require("spec.support.changelog")

local function changelog(...)
    return "# Changelog\n\n" .. table.concat({ ... }, "\n") .. "\n"
end

local function untagged(text) return Changelog.UntaggedEntries(text, "### Unreleased") end

describe("Spec comments", function()
    it("reads the one form (white)", function()
        assert.are.same({ 27 }, Changelog.SpecComment("-- Spec: #27"))
        assert.are.same({ 27, 52 }, Changelog.SpecComment("-- Spec: #27, #52"))
    end)

    it("flags a spec comment in any other form (black)", function()
        for _, line in ipairs({ "--Spec: #27", "-- Specs: #27", "-- spec: #27", "-- Spec #27", "--- Spec: #27",
            "  -- Spec: #27", "-- Spec: 27", "-- Spec: #27,#52", "-- Spec: #27, #27", "-- Spec: #0" }) do
            assert.is_false(Changelog.SpecComment(line), line)
        end
    end)

    it("ignores other lines and junk (red)", function()
        for _, line in ipairs({ "-- Speculative note", "local x = 1", "", "-- Buff back tests", false, nil, 7 }) do
            assert.is_nil(Changelog.SpecComment(line), tostring(line))
        end
    end)

    it("are written in the one form near the top of every spec file", function()
        local listing = io.popen('cd "' .. wow.ROOT .. '" && ls spec/*_spec.lua')
        local found = 0
        for path in listing:lines() do
            local lines = Changelog.Lines(wow.readFile(path))
            for i = 1, math.min(5, #lines) do
                local issues = Changelog.SpecComment(lines[i])
                if issues ~= nil then
                    found = found + 1
                    assert.is_truthy(issues, path .. ": " .. lines[i])
                end
            end
        end
        listing:close()
        assert.is_true(found >= 3, "found " .. found .. " spec comments")
    end)
end)

describe("Changelog", function()
    describe("issue tags (white)", function()
        it("accepts one issue or several", function()
            assert.are.same({ 27 }, Changelog.TagIssues("- Buff back. (#27)"))
            assert.are.same({ 27, 52 }, Changelog.TagIssues("- Restart after updating. (#27, #52)"))
            assert.are.same({ 27 }, Changelog.TagIssues("- Trailing space is fine. (#27)  "))
        end)

        it("passes a section whose entries are all tagged", function()
            assert.are.same({}, untagged(changelog("### Unreleased", "", "- One. (#1)", "- Two. (#2, #3)", "",
                "## 1.6.0", "", "- Old, untagged.")))
        end)
    end)

    describe("issue tags (black)", function()
        it("rejects every malformed tag", function()
            for _, entry in ipairs({
                "- No tag.", "- (#27) Tag first, not last.", "- Hash after. (#27#)", "- Empty part. (#27, )",
                "- Missing hash. (#27, 52)", "- Space inside. (# 27)", "- No comma space. (#27,#52)",
                "- No comma. (#27 #52)", "- Zero. (#0)", "- Leading zero. (#027)", "- Empty. ()",
                "- Not an issue. (see above)", "- Twice. (#27, #27)", "- No space before it.(#27)",
            }) do
                assert.is_nil(Changelog.TagIssues(entry), entry)
            end
        end)

        it("takes off only a well-formed tag, as the release notes do", function()
            assert.are.equal("- One.", Changelog.WithoutTag("- One. (#27)"))
            assert.are.equal("- Two.", Changelog.WithoutTag("- Two. (#27, #52)  "))
            assert.are.equal("- Kept (as written).", Changelog.WithoutTag("- Kept (as written)."))
            assert.are.equal("- Not a tag (#)", Changelog.WithoutTag("- Not a tag (#)"))
        end)

        it("counts a heading that appears twice (a merge that kept both)", function()
            assert.are.equal(2, Changelog.CountHeading(changelog("### Unreleased", "- a (#1)", "### Unreleased",
                "- b"), "### Unreleased"))
        end)

        it("names every untagged entry, with its line and its end", function()
            local text = changelog("### Unreleased", "", "- Tagged. (#1)", "- Untagged one.", "- Untagged two.",
                "", "## 1.6.0")
            local found = untagged(text)
            assert.are.equal(2, #found)
            assert.are.equal(6, found[1].line)
            assert.are.equal("line 6: ...- Untagged one.\nline 7: ...- Untagged two.", Changelog.Describe(found))
        end)

        it("checks entries made with * and + too", function()
            assert.are.equal(2, #untagged(changelog("### Unreleased", "", "* Star.", "+ Plus.")))
        end)
    end)

    describe("unusual changelogs (red)", function()
        it("has nothing to check when there is no Unreleased section (a release PR or tag)", function()
            assert.are.same({}, untagged(changelog("## 1.7.0", "", "- Released. (#5)", "", "## 1.6.0")))
        end)

        it("checks an Unreleased section that is the last one, or empty", function()
            assert.are.equal(1, #untagged(changelog("### Unreleased", "", "- Untagged at the end.")))
            assert.are.same({}, untagged(changelog("### Unreleased", "", "## 1.6.0")))
        end)

        it("keeps checking past a subheading inside the section", function()
            assert.are.equal(1, #untagged(changelog("### Unreleased", "", "- Tagged. (#1)", "", "#### Fixes", "",
                "- Untagged fix.", "", "## 1.6.0")))
            assert.are.same({}, untagged(changelog("### Unreleased", "- Tagged. (#1)", "#### Fixes", "- Fix. (#2)")))
        end)

        it("finds the first section heading, misspelled or not", function()
            assert.are.equal("### Unrelased", Changelog.FirstSectionHeading(changelog("### Unrelased", "- x")))
            assert.are.equal("## 1.7.0", Changelog.FirstSectionHeading(changelog("## 1.7.0  ", "- x")))
            assert.is_nil(Changelog.FirstSectionHeading("# Changelog\n\nno sections"))
        end)

        it("reads Windows line endings", function()
            local text = changelog("### Unreleased", "", "- Tagged. (#1)", "", "## 1.6.0"):gsub("\n", "\r\n")
            assert.are.same({}, untagged(text))
        end)

        it("joins a wrapped entry and checks the tag at its end", function()
            assert.are.same({}, untagged(changelog("### Unreleased", "", "- A long entry that wraps", "  onto a second line. (#1)")))
            assert.are.equal(1, #untagged(changelog("### Unreleased", "", "- Tag on the first line (#1)", "  but not at the end.")))
        end)

        it("doesn't take an indented sub-bullet as the end of its entry", function()
            local text = changelog("### Unreleased", "", "- Main entry. (#1)", "  - a detail", "  - another detail")
            assert.are.same({}, untagged(text))
            assert.are.equal(1, #untagged(changelog("### Unreleased", "", "- Main entry.", "  - a detail (#1)")))
        end)

        it("treats a missing text or entry as nothing to check", function()
            assert.is_nil(Changelog.TagIssues(nil))
            assert.are.same({}, Changelog.UntaggedEntries(nil, "### Unreleased"))
            assert.are.same({}, Changelog.Lines(nil))
            assert.are.same({}, Changelog.EntriesBeforeFirstSection(nil))
            assert.is_nil(Changelog.WithoutTag(nil))
            assert.are.same({}, Changelog.Entries(nil))
            assert.are.equal("", Changelog.Describe(nil))
            assert.is_false(Changelog.IsLater(nil, "1.6.0"))
        end)

        it("never errors on junk", function()
            for _, text in ipairs({ "", "\n\n", "### Unreleased", "### Unreleased\n- \n-\n( #)\n((((", ("-"):rep(5000) }) do
                assert.is_table(untagged(text))
            end
        end)
    end)

    describe("the real changelog", function()
        local text = wow.readFile("CHANGELOG.md")

        -- A misspelled heading would hide the section from the check.
        it("starts with Unreleased, or with the TOC's version on a release", function()
            local first = Changelog.FirstSectionHeading(text)
            local allowed = { ["### Unreleased"] = true, ["## " .. wow.parseToc().Version] = true }
            assert.is_true(allowed[first] == true, "first section heading: " .. tostring(first))
        end)

        it("has no entries above its first section", function()
            local found = Changelog.EntriesBeforeFirstSection(text)
            assert.are.equal(0, #found, found[1] and found[1].text)
        end)

        it("has at most one Unreleased section", function()
            assert.is_true(Changelog.CountHeading(text, "### Unreleased") <= 1, "merge both lists under one heading")
        end)

        it("tags every unreleased entry with its issue", function()
            local found = untagged(text)
            assert.are.same({}, found, Changelog.Describe(found))
        end)

        -- Tags began after 1.6.0; a release PR renames Unreleased to the new
        -- version, which must keep them.
        it("tags every entry of the TOC's version, once it's past 1.6.0", function()
            local version = wow.parseToc().Version
            if not Changelog.IsLater(version, "1.6.0") then
                pending("tags start after 1.6.0; the TOC is " .. version)
                return
            end
            local found = Changelog.UntaggedEntries(text, "## " .. version)
            assert.are.same({}, found, Changelog.Describe(found))
        end)

        it("compares versions by number, not as text", function()
            assert.is_true(Changelog.IsLater("1.10.0", "1.6.0"))
            assert.is_false(Changelog.IsLater("1.6.0", "1.6.0"))
            assert.is_false(Changelog.IsLater("1.5.9", "1.6.0"))
        end)
    end)
end)
