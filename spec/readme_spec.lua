-- Spec: #55
-- The README keeps up with the addon: every /friendly command is written in
-- it, and /friendly help lists every command, so none ships undocumented.
local wow = require("spec.support.wow")

-- Readme text without what a reader doesn't see as documentation: fenced
-- code blocks (``` or ~~~, indented or not, even on the first line) and
-- HTML comments (an unclosed one hides the rest of the text).
local function VisibleText(text)
    text = ("\n" .. text:gsub("\r", "")):gsub("\n[ \t]*([`~][`~][`~]).-\n[ \t]*%1", "\n")
    return (text:gsub("<!%-%-.-%-%->", ""):gsub("<!%-%-.*$", ""))
end

-- A name ends at the end of the text, a space, a backtick, "|", "]", or
-- punctuation; never inside a longer word ("zap" isn't "zap-it").
local function EndsName(text, after)
    local nextChar = text:sub(after, after)
    return nextChar == "" or nextChar:match("[%s`|%]%)%.,:;\"'!?]") ~= nil
end

-- The command names written as "/friendly <name>", or as a word in a chain
-- right after one: "/friendly on | off | toggle" names all three, but
-- "/friendly snooze [minutes] | off" names only snooze.
local function WrittenCommands(readme)
    local text = VisibleText(readme)
    local written = {}
    local position = 1
    while true do
        local start, finish, name = text:find("/friendly ([%w_]+)", position)
        if not start then break end
        if EndsName(text, finish + 1) then
            written[name] = true
            local chainAt = finish + 1
            while true do
                local _, chainEnd, next = text:find("^%s*|%s*([%w_]+)", chainAt)
                if not chainEnd or not EndsName(text, chainEnd + 1) then break end
                -- A word followed by more words is prose (a table cell), not a command.
                if text:find("^[ \t]+[%w_]", chainEnd + 1) then break end
                written[next] = true
                chainAt = chainEnd + 1
            end
        end
        position = finish + 1
    end
    return written
end

-- The names in the list that aren't written.
local function Missing(names, written)
    local missing = {}
    for _, name in ipairs(names) do
        if not written[name] then missing[#missing + 1] = name end
    end
    return missing
end

local function Message(missing) return "missing: " .. table.concat(missing, ", ") end

describe("README", function()
    describe("finding written commands (white)", function()
        it("reads a command alone, in backticks, and in a chain", function()
            local written = WrittenCommands("Type `/friendly status`. `/friendly on | off | toggle`: all.")
            assert.are.same({ on = true, off = true, toggle = true, status = true }, written)
        end)

        it("reads a command at the very end of the text", function()
            assert.is_true(WrittenCommands("type /friendly zap").zap)
        end)
    end)

    describe("finding written commands (black)", function()
        it("doesn't take a subcommand's choice for a command", function()
            local written = WrittenCommands("`/friendly snooze [minutes] | off` and `/friendly profile [new | use]`")
            assert.is_nil(written.off)
            assert.is_nil(written.use)
            assert.is_nil(written.new)
        end)

        it("doesn't take a table cell or a longer word", function()
            local written = WrittenCommands("| none | x |\n`/friendly zap-it` and /friendly statuses")
            assert.is_nil(written.none)
            assert.is_nil(written.zap)
            assert.is_nil(written.status)
        end)

        it("doesn't count a mention in a code block or an HTML comment", function()
            local written = WrittenCommands("text\n```\n/friendly zap\n```\n<!-- /friendly zip -->")
            assert.is_nil(written.zap)
            assert.is_nil(written.zip)
            assert.is_nil(WrittenCommands("```\n/friendly zap\n```").zap, "a fence on the first line")
            assert.is_nil(WrittenCommands("- item\n  ```\n  /friendly zap\n  ```").zap, "an indented fence")
            assert.is_nil(WrittenCommands("~~~\n/friendly zap\n~~~").zap, "a tilde fence")
            assert.is_nil(WrittenCommands("ok\n<!-- unclosed /friendly zap").zap, "an unclosed comment")
        end)

        it("doesn't read on into a table cell's prose", function()
            assert.is_nil(WrittenCommands("| /friendly on | off by default |").off)
        end)

        it("reads a command before quotes and sentence punctuation", function()
            local written = WrittenCommands('Try "/friendly zap"! Or /friendly zip? Or \'/friendly zop\'.')
            assert.is_true(written.zap and written.zip and written.zop)
        end)
    end)

    describe("finding written commands (red)", function()
        it("never errors on odd text", function()
            for _, text in ipairs({ "", "/friendly", "/friendly ", "/friendly |||", "```", "<!--", ("/friendly a | "):rep(500) }) do
                assert.is_table(WrittenCommands(text))
            end
        end)

        it("reports a command taken out of the real README", function()
            local readme = wow.readFile("README.md"):gsub("/friendly move", "/friendly zzz")
            local missing = Missing({ "move", "status" }, WrittenCommands(readme))
            assert.are.same({ "move" }, missing)
        end)

        it("reads a README with Windows line endings", function()
            local written = WrittenCommands(("a\n```\n/friendly zap\n```\n/friendly on\n"):gsub("\n", "\r\n"))
            assert.is_nil(written.zap)
            assert.is_true(written.on)
        end)
    end)

    describe("the real README and addon", function()
        local ns
        before_each(function() ns = wow.boot() end)

        it("writes every /friendly command", function()
            local names = ns.SlashCommandNames()
            local isCommand = {}
            for _, name in ipairs(names) do isCommand[name] = true end
            for _, known in ipairs({ "on", "help", "ledger", "buffback" }) do
                assert.is_true(isCommand[known] == true, known .. " isn't a command any more?")
            end
            local missing = Missing(names, WrittenCommands(wow.readFile("README.md")))
            assert.are.same({}, missing, Message(missing))
        end)

        it("lists every command in /friendly help", function()
            wow.printed = {}
            _G.SlashCmdList.FRIENDLYFOREVER("help")
            local missing = Missing(ns.SlashCommandNames(), WrittenCommands(table.concat(wow.printed, "\n")))
            -- help is the command being run; it needn't list itself.
            for i = #missing, 1, -1 do
                if missing[i] == "help" then table.remove(missing, i) end
            end
            assert.are.same({}, missing, Message(missing))
        end)
    end)
end)
