-- Spec: #55
-- The README keeps up with the addon: every /friendly command is written in
-- it, and /friendly help lists every command, so none ships undocumented.
local wow = require("spec.support.wow")

-- The text with each [opening, closing] span cut out, in one pass (linear
-- however many are left open). openAt(text, from) and closeAt(text, from)
-- return where the next opening or closing starts and ends. An opening never
-- closed hides the rest of the text.
local function Cut(text, openAt, closeAt)
    local kept, at = {}, 1
    while true do
        local from, openEnd = openAt(text, at)
        if not from then kept[#kept + 1] = text:sub(at) break end
        kept[#kept + 1] = text:sub(at, from - 1)
        local _, closeEnd = closeAt(text, openEnd + 1)
        if not closeEnd then break end
        at = closeEnd + 1
    end
    return table.concat(kept)
end

-- An HTML comment: "<!--" to "-->", where "<!-->" and "<!--->" are empty ones.
local function CommentOpen(text, from) return text:find("<!%-%-", from) end
local function CommentClose(text, from)
    local empty, emptyEnd = text:find("^%-?>", from)
    if empty then return empty, emptyEnd end
    return text:find("-->", from, true)
end

-- A <pre> block, in any case and with any attributes.
local function PreOpen(text, from)
    local start, nameEnd, after = text:find("<[Pp][Rr][Ee]([%s>])", from)
    if not start then return nil end
    if after == ">" then return start, nameEnd end
    -- Attributes: the tag ends at the next ">" (none: the rest is hidden).
    local close = text:find(">", nameEnd + 1, true)
    return start, close or #text
end
local function PreClose(text, from) return text:find("</[Pp][Rr][Ee]%s*>", from) end

-- Readme text without what a reader doesn't see as documentation: fenced
-- code blocks (``` or ~~~, indented or not, even on the first line), <pre>
-- blocks and HTML comments. An unclosed one hides the rest of the text.
-- A "<" inside inline code is just a character, not a tag. (Lines indented
-- four spaces aren't treated as code: in this README they are list
-- continuations.)
local function VisibleText(text)
    text = ("\n" .. text:gsub("\r\n?", "\n")):gsub("\n[ \t]*([`~][`~][`~]).-\n[ \t]*%1", "\n")
    text = text:gsub("\n[ \t]*```.*$", ""):gsub("\n[ \t]*~~~.*$", "")
    text = text:gsub("`[^`\n]+`", function(span) return (span:gsub("<", "&lt;")) end)
    return Cut(Cut(text, PreOpen, PreClose), CommentOpen, CommentClose)
end

-- A name ends at the end of the text, a space, a backtick, "|", "]", or
-- punctuation; never inside a longer word ("zap" isn't "zap-it").
local function EndsName(text, after)
    local nextChar = text:sub(after, after)
    return not nextChar:match("[%w%-]")
end

-- A table's delimiter row: only pipes, colons, dashes and spaces, with at
-- least one dash and one pipe ("|---|:-:|", "--- | ---").
local function IsDelimiterRow(line)
    return line:find("^[ \t|:%-]+$") ~= nil and line:find("-", 1, true) ~= nil and line:find("|", 1, true) ~= nil
end

-- Which lines are table rows: those with outer pipes, and every line of a
-- run of lines with pipes that includes a delimiter row (a table written
-- without outer pipes).
local function TableRows(lines)
    local rows, first = {}, nil
    for i = 1, #lines + 1 do
        local line = lines[i]
        if line and line:find("^[ \t]*|.*|[ \t]*$") then rows[i] = true end
        if line and line:find("|", 1, true) then
            first = first or i
        else
            if first then
                local hasDelimiter = false
                for j = first, i - 1 do hasDelimiter = hasDelimiter or IsDelimiterRow(lines[j]) end
                if hasDelimiter then for j = first, i - 1 do rows[j] = true end end
            end
            first = nil
        end
    end
    return rows
end

-- The command names written as "/friendly <name>", or as a word in a chain
-- right after one: "/friendly on | off | toggle" names all three, but
-- "/friendly snooze [minutes] | off" names only snooze.
local function WrittenCommands(readme)
    local written, lines = {}, {}
    for line in (VisibleText(readme) .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
    local tableRows = TableRows(lines)
    for index, line in ipairs(lines) do
        -- In a table row an unescaped "|" ends the cell, never a chain.
        local chain = tableRows[index] and "^[ \t]*\\|[ \t]*(%w+)" or "^[ \t]*\\?|[ \t]*(%w+)"
        local position = 1
        while true do
            local start, finish, name = line:find("/friendly (%w+)", position)
            if not start then break end
            -- Not part of a longer path or word ("example.com/friendly zap").
            local before = line:sub(start - 1, start - 1)
            if EndsName(line, finish + 1) and not before:match("[%w%./]") then
                written[name] = true
                local chainAt = finish + 1
                while true do
                    local _, chainEnd, next = line:find(chain, chainAt)
                    if not chainEnd or not EndsName(line, chainEnd + 1) then break end
                    -- A word followed by more words is prose, not a command.
                    if line:find("^[ \t]+%w", chainEnd + 1) then break end
                    written[next] = true
                    chainAt = chainEnd + 1
                end
            end
            position = finish + 1
        end
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

describe("README test helpers (review: kill tests)", function()
    it("reads text after a closed HTML comment, and between two", function()
        assert.is_true(WrittenCommands("<!-- note -->\n/friendly zap").zap)
        assert.is_true(WrittenCommands("<!-- a --> /friendly zap <!-- b -->").zap)
    end)

    it("closes a fence only with its own kind of fence", function()
        local written = WrittenCommands("~~~\n```lua\n~~~\n/friendly zap\n```\ncode\n```")
        assert.is_true(written.zap)
        assert.is_nil(written.code)
    end)

    it("keeps the line break a fence stood on", function()
        assert.is_true(WrittenCommands("/friendly zap\n~~~\ncode\n~~~~").zap, "a longer closing fence")
    end)

    it("doesn't take two backticks for a fence", function()
        assert.is_true(WrittenCommands("``a`` b\n/friendly zap\n``c`` d").zap)
    end)

    it("ends a name at each punctuation mark", function()
        local written = WrittenCommands(
            "/friendly za! /friendly zb; /friendly zc: /friendly zd, /friendly ze. (/friendly zf) [/friendly zg] |/friendly zh|")
        for _, name in ipairs({ "za", "zb", "zc", "zd", "ze", "zf", "zg", "zh" }) do
            assert.is_true(written[name], name)
        end
    end)

    it("needs /friendly and one space before the name", function()
        assert.is_nil(WrittenCommands("Type /friendly\nto open the options.").to)
        assert.is_nil(WrittenCommands("Send a friendly hello.").hello)
    end)

    it("reads a chain with no spaces, and a mention right after a name", function()
        assert.are.same({ on = true, off = true, toggle = true }, WrittenCommands("/friendly on|off|toggle"))
        assert.are.same({ on = true, off = true }, WrittenCommands("/friendly on  |  off"))
        -- Written straight after a name, "/friendly" is part of a word, as in a path.
        assert.is_nil(WrittenCommands("/friendly on/friendly zap").zap)
        assert.is_true(WrittenCommands("/friendly on (/friendly zap)").zap)
    end)

    it("doesn't read a longer word, a number or a tab-spaced cell in a chain", function()
        assert.is_nil(WrittenCommands("/friendly on | zap-it").zap)
        assert.is_nil(WrittenCommands("/friendly snooze | off 15 minutes").off)
        assert.is_nil(WrittenCommands("| /friendly on | off\tby default |").off)
    end)
end)

describe("ns.SlashCommandNames (review)", function()
    local ns
    before_each(function() ns = wow.boot() end)

    it("is sorted with no repeats, and a fresh table each call", function()
        local names = ns.SlashCommandNames()
        for i = 2, #names do assert.is_true(names[i - 1] < names[i], names[i - 1] .. " before " .. names[i]) end
        names[1] = nil
        assert.is_not_nil(ns.SlashCommandNames()[1])
    end)

    it("holds every command help and the README name (none left out)", function()
        local isCommand = {}
        for _, name in ipairs(ns.SlashCommandNames()) do isCommand[name] = true end
        wow.printed = {}
        _G.SlashCmdList.FRIENDLYFOREVER("help")
        for _, source in ipairs({ table.concat(wow.printed, "\n"), wow.readFile("README.md") }) do
            for name in pairs(WrittenCommands(source)) do
                assert.is_true(isCommand[name], "/friendly " .. name .. " is written but isn't a command")
            end
        end
    end)
end)

describe("README test helpers (review: findings)", function()
    it("reads a command in bold, italics or HTML", function()
        for _, text in ipairs({ "**/friendly zap**", "*/friendly zap*", "_/friendly zap_", "__/friendly zap__",
            "<code>/friendly zap</code>", "| /friendly zap<br>and more |" }) do
            assert.is_true(WrittenCommands(text).zap, text)
        end
    end)

    it("doesn't take the next table cell for a command", function()
        assert.is_nil(WrittenCommands("| Command | Default |\n|---|---|\n| /friendly debug | off |").off)
        assert.is_nil(WrittenCommands("| `/friendly minimap` | on |").on)
    end)

    it("hides the rest of the text after an unclosed fence, as it does after an unclosed comment", function()
        assert.is_nil(WrittenCommands("ok\n```\n/friendly zap").zap)
    end)

    it("doesn't read /friendly inside a path or word, or in a <pre> block", function()
        assert.is_nil(WrittenCommands("See example.com/friendly zap").zap)
        assert.is_nil(WrittenCommands("foo/friendly zap").zap)
        assert.is_nil(WrittenCommands("<pre>\n/friendly zap\n</pre>").zap)
        assert.is_nil(WrittenCommands("ok <pre>/friendly zap").zap)
        assert.is_true(WrittenCommands("(/friendly zap)").zap)
    end)

    it("strips many unclosed comments in linear time", function()
        local started = os.clock()
        assert.is_table(WrittenCommands(("<!--"):rep(20000)))
        assert.is_true(os.clock() - started < 1)
    end)
end)

describe("README test helpers (review round 2: kill tests)", function()
    it("reads old Mac line endings as line breaks", function()
        local written = WrittenCommands("a\r```\r/friendly zap\r```\r/friendly on\r")
        assert.is_nil(written.zap)
        assert.is_true(written.on)
    end)

    it("reads on after an indented fence closes", function()
        local written = WrittenCommands("- item\n  ```\n  /friendly zip\n  ```\n/friendly zap")
        assert.is_nil(written.zip)
        assert.is_true(written.zap)
    end)

    it("hides the rest after an unclosed tilde or indented fence, but not after inline backticks", function()
        assert.is_nil(WrittenCommands("ok\n~~~\n/friendly zap").zap)
        assert.is_nil(WrittenCommands("ok\n  ~~~\n/friendly zap").zap)
        assert.is_nil(WrittenCommands("ok\n  ```\n/friendly zap").zap)
        assert.is_true(WrittenCommands("text ``` more\n/friendly zap").zap)
    end)

    it("reads on after a closed <pre>, and between two", function()
        assert.is_true(WrittenCommands("<pre>x</pre> /friendly zap").zap)
        assert.is_true(WrittenCommands("<pre>a</pre> /friendly zap <pre>b</pre>").zap)
        assert.is_true(WrittenCommands("<pre>a</pre>/friendly zap").zap)
    end)

    it("cuts exactly the comment out, and only at -->", function()
        assert.are.equal("\na  b", VisibleText("a <!-- c --> b"))
        assert.are.equal("\na  b", VisibleText("a <!----> b"))
        assert.are.equal("\na  c", VisibleText("a <!-- x -> y --> c"))
    end)

    it("treats a padded row as a table row", function()
        assert.is_nil(WrittenCommands("  | /friendly debug | off |  ").off)
    end)

    it("reads an escaped pipe chain outside a table", function()
        assert.are.same({ on = true, off = true }, WrittenCommands("/friendly on \\| off"))
    end)

    it("doesn't read /friendly in a relative path or after //", function()
        assert.is_nil(WrittenCommands("see ../friendly zap").zap)
        assert.is_nil(WrittenCommands("see https://friendly zap").zap)
    end)

    it("stops a chain at a tab or double space before prose", function()
        assert.is_nil(WrittenCommands("/friendly on | off\tby default").off)
        assert.is_nil(WrittenCommands("/friendly on | off  by default").off)
    end)

    it("strips many unclosed <pre> tags in linear time", function()
        local started = os.clock()
        assert.is_table(WrittenCommands(("<pre>"):rep(20000)))
        assert.is_table(WrittenCommands(("<pre> x "):rep(20000)))
        assert.is_true(WrittenCommands(("<pre>a</pre>"):rep(20000) .. " /friendly zap").zap)
        assert.is_true(os.clock() - started < 1)
    end)
end)

describe("README test helpers (review round 2: nits)", function()
    it("reads a table written without outer pipes", function()
        assert.is_nil(WrittenCommands("Cmd | Default\n--- | ---\n/friendly debug | off").off)
        assert.is_true(WrittenCommands("Cmd | Default\n--- | ---\n/friendly debug | off").debug)
        assert.is_true(WrittenCommands("/friendly on | off").off, "no delimiter row: a chain, not a table")
    end)

    it("treats <!--> and <!---> as empty comments", function()
        assert.is_true(WrittenCommands("<!--> /friendly zap").zap)
        assert.is_true(WrittenCommands("<!---> /friendly zap").zap)
    end)

    it("strips <pre> in any case and with attributes", function()
        assert.is_nil(WrittenCommands("<PRE>/friendly zap</PRE>").zap)
        assert.is_nil(WrittenCommands('<pre class="x">\n/friendly zap\n</pre>').zap)
        assert.is_true(WrittenCommands("<prefix> /friendly zap").zap, "a different tag")
    end)

    it("takes <pre> or <!-- inside inline code as text, not a tag", function()
        assert.is_true(WrittenCommands("Use `<pre>` for code. /friendly zap").zap)
        assert.is_true(WrittenCommands("Write `<!--` to start. /friendly zap").zap)
    end)
end)
