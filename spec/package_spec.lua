-- Builds the release zip and checks it has the layout WoW and CurseForge
-- expect, with nothing but runtime files inside.
local wow = require("spec.support.wow")

describe("Release package", function()
    local entries

    setup(function()
        local build = io.popen('"' .. wow.ROOT .. 'scripts/package.sh" 2>&1')
        local zipPath = build:read("*a"):match("([^\n]*%.zip)")
        build:close()
        assert.is_truthy(zipPath, "package script did not report a zip")

        entries = {}
        local list = io.popen('unzip -Z1 "' .. zipPath .. '"')
        for line in list:read("*a"):gmatch("[^\n]+") do entries[#entries + 1] = line end
        list:close()
    end)

    local function has(path)
        for _, e in ipairs(entries) do if e == path then return true end end
        return false
    end

    it("is named after the TOC version", function()
        local meta = wow.parseToc()
        local handle = io.open(wow.ROOT .. "dist/FriendlyForever-" .. meta.Version .. ".zip")
        assert.is_truthy(handle)
        handle:close()
    end)

    it("has a single FriendlyForever/ folder at the top", function()
        for _, e in ipairs(entries) do
            assert.is_truthy(e:find("^FriendlyForever/"), e)
        end
    end)

    it("contains the TOC and every file it loads", function()
        assert.is_true(has("FriendlyForever/FriendlyForever.toc"))
        local _, files = wow.parseToc()
        for _, file in ipairs(files) do
            assert.is_true(has("FriendlyForever/" .. file), file)
        end
    end)

    it("contains no tests, tooling or editor files", function()
        for _, e in ipairs(entries) do
            assert.is_nil(e:find("spec/", 1, true), e)
            assert.is_nil(e:find("scripts/", 1, true), e)
            assert.is_nil(e:find("/%."), e) -- dotfiles: .luacheckrc, .vscode, .github...
            assert.is_nil(e:find("Makefile", 1, true), e)
        end
    end)

    it("ships the README, changelog and license", function()
        assert.is_true(has("FriendlyForever/README.md"))
        assert.is_true(has("FriendlyForever/CHANGELOG.md"))
        assert.is_true(has("FriendlyForever/LICENSE"))
    end)

    it("has release notes for the TOC version at the top of the changelog", function()
        local meta = wow.parseToc()
        local first = wow.readFile("CHANGELOG.md"):match("\n## ([^\n]+)")
        assert.are.equal(meta.Version, first)
    end)
end)
