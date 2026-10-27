-- Spec: #51
local Changelog = require("spec.support.changelog")
local function changelog(...) return "# Changelog\n\n" .. table.concat({ ... }, "\n") .. "\n" end
local function untagged(text) return Changelog.UntaggedEntries(text, "### Unreleased") end

describe("Changelog checker (round 2)", function()
    it("takes a line indented four spaces for code, not a heading", function()
        assert.are.equal("## 1.6.0", Changelog.FirstSectionHeading(changelog("    ### Unreleased", "", "## 1.6.0")))
    end)

    it("reads an entry numbered with a parenthesis", function()
        assert.are.equal(1, #untagged(changelog("### Unreleased", "", "1) Paren numbered.")))
    end)

    it("keeps numbered sub-steps out of the entry", function()
        assert.are.same({}, untagged(changelog("### Unreleased", "", "- Main. (#1)", "  1. step one", "  2) step two")))
    end)

    it("finds a stray entry right under the title", function()
        assert.are.equal(1, #Changelog.EntriesBeforeFirstSection(changelog("- Stray.", "", "## 1.6.0")))
    end)

    it("release notes keep a tag followed by a Unicode space, whatever the locale", function()
        local dir = os.tmpname()
        os.remove(dir)
        os.execute('mkdir -p "' .. dir .. '"')
        local file = io.open(dir .. "/C.md", "wb")
        file:write("## 9.9.9\n- Em space. (#27)\226\128\131\n")
        file:close()
        os.execute('LC_ALL=C.UTF-8 ./scripts/release-notes.sh "' .. dir .. '/C.md" "' .. dir .. '/N.md" >/dev/null 2>&1')
        local notes = io.open(dir .. "/N.md", "rb"):read("*a")
        os.execute('rm -rf "' .. dir .. '"')
        assert.are.equal("## 9.9.9\n- Em space. (#27)\226\128\131\n", notes)
    end)

    describe("#defect", function()
        it("counts an Unreleased heading indented by a space as a second one", function()
            assert.are.equal(2, Changelog.CountHeading(changelog("### Unreleased", "- a (#1)", " ### Unreleased", "- b"),
                "### Unreleased"))
        end)

        it("ends an entry at an indented subheading", function()
            assert.are.same({}, untagged(changelog("### Unreleased", "", "- Tagged. (#1)", " #### Fixes", "- Fix. (#2)")))
        end)
    end)
end)
