-- Spec: #51
local Changelog = require("spec.support.changelog")
local function changelog(...) return "# Changelog\n\n" .. table.concat({ ... }, "\n") .. "\n" end
local function untagged(text) return Changelog.UntaggedEntries(text, "### Unreleased") end

describe("Changelog checker (round 3)", function()
    it("keeps a wrapped line that starts with # in its entry", function()
        assert.are.same({}, untagged(changelog("### Unreleased", "", "- Fix the bug", "  #3 in the list. (#5)")))
    end)

    it("ends an entry at an empty heading", function()
        assert.are.same({}, untagged(changelog("### Unreleased", "", "- Tagged. (#1)", "####", "- Next. (#2)")))
    end)

    it("compares nothing when either version is missing", function()
        assert.is_false(Changelog.IsLater("1.7.0", nil))
        assert.is_false(Changelog.IsLater(nil, "1.7.0"))
    end)
end)
