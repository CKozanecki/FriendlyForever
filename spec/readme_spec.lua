-- Spec: #55
-- The README keeps up with the addon: every /friendly command in Core.lua is
-- named in it, so a new command can't ship undocumented.
local wow = require("spec.support.wow")

-- The command names in Core.lua's `local commands = { ... }` table.
local function CommandNames(coreText)
    local block = coreText:match("\nlocal commands = {\n(.-)\n}") or ""
    local names = {}
    for name in (block .. "\n"):gmatch("\n?    ([%a_][%w_]*) = ") do names[#names + 1] = name end
    table.sort(names)
    return names
end

-- The commands the README never writes as "/friendly <name>".
local function Undocumented(names, readmeText)
    local missing = {}
    for _, name in ipairs(names) do
        local written = readmeText:find("/friendly " .. name .. "[^%w_]") or readmeText:find("| " .. name .. "[ `|]")
        if not written then missing[#missing + 1] = name end
    end
    return missing
end

describe("README", function()
    describe("command coverage (white and black)", function()
        local core = "local x = 1\nlocal commands = {\n    on = function() end,\n    status = PrintStatus,\n}\n"

        it("reads the command table", function()
            assert.are.same({ "on", "status" }, CommandNames(core))
            assert.are.same({}, CommandNames("no table here"))
        end)

        it("passes when every command is written, alone or in a list", function()
            assert.are.same({}, Undocumented({ "on", "status" }, "`/friendly status` and `/friendly on | off`"))
        end)

        it("names each command that isn't", function()
            assert.are.same({ "status" }, Undocumented({ "on", "status" }, "`/friendly on` and `/friendly statuses`"))
        end)
    end)

    it("names every /friendly command in Core.lua", function()
        local names = CommandNames(wow.readFile("Core.lua"))
        assert.is_true(#names >= 20, "found only " .. #names .. " commands; did the table move?")
        assert.are.same({}, Undocumented(names, wow.readFile("README.md")))
    end)
end)
