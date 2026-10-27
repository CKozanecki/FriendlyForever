-- Reads CHANGELOG.md's sections and entries, and the issue tags entries end
-- with (CONTRIBUTING.md, "Specs and traceability"). Every function works on
-- text, not on the file, so the specs can feed it made-up changelogs.
local Changelog = {}

-- The issue numbers of an entry's tag, " (#27)" or " (#27, #52)" at the
-- very end of the entry (after a space), or nil when it has no well-formed tag (or names an
-- issue twice).
function Changelog.TagIssues(entry)
    if type(entry) ~= "string" then return nil end
    local inside = entry:match(" %(([^()]*)%)%s*$")
    if not inside then return nil end
    local issues, seen = {}, {}
    for part in (inside .. ", "):gmatch("(.-), ") do
        local number = tonumber(part:match("^#([1-9]%d*)$"))
        if not number or seen[number] then return nil end
        seen[number] = true
        issues[#issues + 1] = number
    end
    return issues
end

-- The entry with its well-formed tag (and the space before it) taken off,
-- as the release notes show it; anything else is left as written.
function Changelog.WithoutTag(entry)
    if type(entry) ~= "string" then return entry end
    -- By form alone, as release-notes.sh's sed does: "(#27, #27)" goes too.
    local inside = entry:match(" %(([^()]*)%)%s*$")
    if not inside or (inside .. ", "):gsub("#[1-9]%d*, ", "") ~= "" then return entry end
    return (entry:gsub(" %([^()]*%)%s*$", ""))
end

-- Whether a line starts a section of its own: a release ("## 1.7.0") or
-- the next release's notes ("### Unreleased"). Other headings inside a
-- section ("#### Fixes") are part of it.
local function Heading(line)
    return (line:match("^ ? ? ?(##+ .-)%s*$"))
end

local function StartsSection(line)
    local heading = Heading(line)
    return heading ~= nil and (heading:match("^## ") ~= nil or heading == "### Unreleased")
end

-- How many times a heading line appears (indented or not, as Section reads it).
function Changelog.CountHeading(text, heading)
    local count = 0
    for _, line in ipairs(Changelog.Lines(text)) do
        if Heading(line) == heading then count = count + 1 end
    end
    return count
end

-- The lines, with every carriage return removed.
function Changelog.Lines(text)
    local lines = {}
    if type(text) ~= "string" then return lines end
    -- Every CR goes, as release-notes.sh's tr -d '\r' removes them.
    for line in (text:gsub("\r", "") .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
    return lines
end

-- The first section heading ("### Unreleased" or "## 1.7.0"), or nil.
function Changelog.FirstSectionHeading(text)
    for _, line in ipairs(Changelog.Lines(text)) do
        if Heading(line) then return Heading(line) end
    end
end

-- The lines under a heading (the whole heading line, such as "### Unreleased"
-- or "## 1.7.0"), up to the next section or the end, and the line number of
-- the first of them. nil when there is no such heading.
function Changelog.Section(text, heading)
    local lines, firstLine, found, inside = {}, nil, false, false
    for number, line in ipairs(Changelog.Lines(text)) do
        if inside and StartsSection(line) then break end
        if not inside and Heading(line) == heading then
            inside, found, firstLine = true, true, number + 1
        elseif inside then
            lines[#lines + 1] = line
        end
    end
    if not found then return nil end
    return lines, firstLine
end

-- The entries in a section's lines: each top-level bullet ("- ", "* " or
-- "+ " at the start of a line) with the lines that wrap it. An indented
-- sub-bullet and its own lines aren't part of the entry's text, and a blank
-- line or a heading ends an entry. Each entry is { text, line, last }: line
-- is its first line's index in lines, last its last line's text.
function Changelog.Entries(lines)
    local entries, parts, current, inSubBullet = {}, {}, nil, false
    if type(lines) ~= "table" then return entries end
    -- Each entry's lines are gathered in a list and joined once (joining as
    -- they come would take time growing with the square of the length).
    local function finish()
        if current then current.text = table.concat(parts[current], " ") end
    end
    for index, line in ipairs(lines) do
        if line:match("^ ?[-*+][ \t]") or line:match("^ ?%d+[.)][ \t]") then
            finish()
            current, inSubBullet = { line = index, last = line }, false
            parts[current] = { line }
            entries[#entries + 1] = current
        elseif not line:match("%S") or (line:match("^ ? ? ?#+[ \t]") or line:match("^ ? ? ?#+$")) then
            finish()
            current = nil
        elseif current and (line:match("^%s+[-*+][ \t]") or line:match("^%s+%d+[.)][ \t]")) then
            inSubBullet = true
        elseif current and not inSubBullet then
            table.insert(parts[current], (line:match("^%s*(.-)$")))
            current.last = line
        end
    end
    finish()
    return entries
end

-- The entries under a heading without a well-formed issue tag, each as
-- { text, line } with line the line number in the whole text. Empty when
-- the heading isn't there: no section, nothing to check.
function Changelog.UntaggedEntries(text, heading)
    local lines, firstLine = Changelog.Section(text, heading)
    local untagged = {}
    if not lines then return untagged end
    for _, entry in ipairs(Changelog.Entries(lines)) do
        if not Changelog.TagIssues(entry.text) or not Changelog.TagIssues(entry.last) then
            untagged[#untagged + 1] = { text = entry.text, line = firstLine + entry.line - 1 }
        end
    end
    return untagged
end

-- "line N: ...end of the entry" for each untagged entry, for a failure message.
function Changelog.Describe(untagged)
    local out = {}
    if type(untagged) ~= "table" then return "" end
    for _, entry in ipairs(untagged) do
        out[#out + 1] = ("line %d: ...%s"):format(entry.line, entry.text:sub(-60))
    end
    return table.concat(out, "\n")
end

-- The entries above the first section heading, which no section check sees.
function Changelog.EntriesBeforeFirstSection(text)
    local lines = {}
    for _, line in ipairs(Changelog.Lines(text)) do
        if Heading(line) then break end
        lines[#lines + 1] = line
    end
    return Changelog.Entries(lines)
end

-- What a line near the top of a spec file says about its issues: the
-- issue numbers for "-- Spec: #27" or "-- Spec: #27, #52"; false for a
-- comment that looks like one but isn't in that form ("--Spec #27",
-- "  -- specs: 27"); nil for any other line.
function Changelog.SpecComment(line)
    if type(line) ~= "string" then return nil end
    if not line:match("^%s*%-%-+%s*[Ss][Pp][Ee][Cc][Ss]?[:%s]") then return nil end
    local issues = line:match("^%-%- Spec: (#[^()]*)$")
    return issues and Changelog.TagIssues(" (" .. issues .. ")") or false
end

-- Whether version a ("1.7.0") comes after version b.
function Changelog.IsLater(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then return false end
    local function parts(version)
        local list = {}
        for number in version:gmatch("%d+") do list[#list + 1] = tonumber(number) end
        return list
    end
    local pa, pb = parts(a), parts(b)
    for i = 1, math.max(#pa, #pb) do
        local x, y = pa[i] or 0, pb[i] or 0
        if x ~= y then return x > y end
    end
    return false
end

return Changelog
