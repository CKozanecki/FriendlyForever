-- Checks the GitHub workflows and the CurseForge packager config. Mistakes
-- here only show up on GitHub or after a release ships, so they're caught
-- here instead.
local wow = require("spec.support.wow")

-- Splits a workflow into its steps (each "- name:" or "- uses:" item) in order.
local function steps(path)
    local list, current = {}, nil
    for line in wow.readFile(path):gmatch("[^\n]*") do
        if line:match("^      %- ") then
            current = { text = "" }
            list[#list + 1] = current
        end
        if current then current.text = current.text .. line .. "\n" end
    end
    return list
end

local function indexOf(list, pattern)
    for i, step in ipairs(list) do
        if step.text:find(pattern) then return i end
    end
end

local WORKFLOWS = { ".github/workflows/ci.yml", ".github/workflows/release.yml" }

describe("Workflows", function()
    it("pin every action to a full commit SHA", function()
        for _, path in ipairs(WORKFLOWS) do
            for ref in wow.readFile(path):gmatch("uses:%s*([^%s#]+)") do
                assert.is_truthy(ref:match("@%x+$") and #ref:match("@(%x+)$") == 40,
                    path .. ": " .. ref .. " is not pinned to a commit SHA")
            end
        end
    end)

    it("install the readline headers before building Lua", function()
        for _, path in ipairs(WORKFLOWS) do
            local list = steps(path)
            local setup = indexOf(list, "make setup")
            local headers = indexOf(list, "libreadline%-dev")
            assert.is_truthy(setup, path .. " never runs make setup")
            assert.is_truthy(headers and headers < setup, path .. " builds Lua before installing libreadline-dev")
        end
    end)

    it("check pull requests with lint, tests and packaging", function()
        local ci = wow.readFile(".github/workflows/ci.yml")
        assert.is_truthy(ci:find("\n  pull_request:"), "CI does not run on pull requests")
        for _, target in ipairs({ "make lint", "make test", "make package" }) do
            assert.is_truthy(ci:find(target, 1, true), "CI never runs " .. target)
        end
    end)

    it("only release from main, at the TOC version, after tests and approval", function()
        local text = wow.readFile(".github/workflows/release.yml")
        assert.is_truthy(text:find("environment: release", 1, true), "release skips the approval environment")

        local list = steps(".github/workflows/release.yml")
        local upload = indexOf(list, "BigWigsMods/packager@")
        assert.is_truthy(upload, "release never runs the packager")
        for _, gate in ipairs({ "merge%-base %-%-is%-ancestor", "FriendlyForever%.toc", "make test" }) do
            local at = indexOf(list, gate)
            assert.is_truthy(at and at < upload, "release uploads before checking " .. gate)
        end
    end)
end)

describe("CurseForge packager config", function()
    -- The packager zips the repo minus .pkgmeta's ignore list (and dotfiles);
    -- scripts/package.sh builds the same zip from the TOC. Every top-level
    -- entry must be shipped by the TOC or ignored, so the two never differ.
    it("ignores every top-level file the TOC doesn't ship", function()
        local ignored = {}
        for entry in wow.readFile(".pkgmeta"):match("ignore:\n(.-)\n\n"):gmatch("%- ([^\n]+)") do
            ignored[entry] = true
        end
        local shipped = { ["FriendlyForever.toc"] = true, ["README.md"] = true,
            ["CHANGELOG.md"] = true, ["LICENSE"] = true }
        local _, files = wow.parseToc()
        for _, file in ipairs(files) do shipped[file:match("^[^/]+")] = true end

        local list = io.popen('cd "' .. wow.ROOT .. '" && (git ls-files 2>/dev/null || ls -A)')
        for path in list:read("*a"):gmatch("[^\n]+") do
            local top = path:match("^[^/]+")
            if top:sub(1, 1) ~= "." then
                assert.is_truthy(shipped[top] or ignored[top], top .. " would ship to CurseForge; add it to .pkgmeta ignore")
            end
        end
        list:close()
    end)
end)
