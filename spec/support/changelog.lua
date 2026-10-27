-- Reads CHANGELOG.md's sections and entries, and the issue tags entries end
-- with (CONTRIBUTING.md, "Specs and traceability"). Every function works on
-- text, not on the file, so the specs can feed it made-up changelogs.
local Changelog = {}

-- The issue numbers of an entry's tag, "(#27)" or "(#27, #52)" at the very
-- end of the entry, or nil when it has no well-formed tag (or names an
-- issue twice).
function Changelog.TagIssues(entry)
    local inside = entry:match("%(([^()]*)%)%s*$")
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

-- Whether a line starts a section of its own: a release ("## 1.7.0") or
-- the next release's notes ("### Unreleased"). Other headings inside a
-- section ("#### Fixes") are part of it.
local function StartsSection(line)
    return line:match("^## ") ~= nil or line:gsub("%s+$", "") == "### Unreleased"
end

-- The lines with Windows line endings removed.
function Changelog.Lines(text)
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = (line:gsub("\r$", "")) end
    return lines
end

-- The first section heading ("### Unreleased" or "## 1.7.0"), or nil.
function Changelog.FirstSectionHeading(text)
    for _, line in ipairs(Changelog.Lines(text)) do
        if line:match("^##+ ") then return (line:gsub("%s+$", "")) end
    end
end

-- The lines under a heading (the whole heading line, such as "### Unreleased"
-- or "## 1.7.0"), up to the next section or the end, and the line number of
-- the first of them. nil when there is no such heading.
function Changelog.Section(text, heading)
    local lines, firstLine, found, inside = {}, nil, false, false
    for number, line in ipairs(Changelog.Lines(text)) do
        if inside and StartsSection(line) then break end
        if not inside and line:match("^##+ ") and line:gsub("%s+$", "") == heading then
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
-- line or a heading ends an entry. Each entry is { text, line } (line: its index in lines).
function Changelog.Entries(lines)
    local entries, current, inSubBullet = {}, nil, false
    for index, line in ipairs(lines) do
        if line:match("^[-*+] ") then
            current, inSubBullet = { text = line, line = index }, false
            entries[#entries + 1] = current
        elseif not line:match("%S") or line:match("^#") then
            current = nil
        elseif current and line:match("^%s+[-*+] ") then
            inSubBullet = true
        elseif current and not inSubBullet then
            current.text = current.text .. " " .. line:match("^%s*(.-)$")
        end
    end
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
        if not Changelog.TagIssues(entry.text) then
            untagged[#untagged + 1] = { text = entry.text, line = firstLine + entry.line - 1 }
        end
    end
    return untagged
end

-- "line N: ...end of the entry" for each untagged entry, for a failure message.
function Changelog.Describe(untagged)
    local out = {}
    for _, entry in ipairs(untagged) do
        out[#out + 1] = ("line %d: ...%s"):format(entry.line, entry.text:sub(-60))
    end
    return table.concat(out, "\n")
end

-- Whether version a ("1.7.0") comes after version b.
function Changelog.IsLater(a, b)
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
