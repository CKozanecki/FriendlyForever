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

-- Changelog fragments (#261). Between releases each pull request adds its
-- note as a file of its own, changes/<issue>.md (a second PR on the same
-- issue: changes/<issue>-<word>.md), instead of a line under "### Unreleased",
-- so two PRs never edit the same lines. The release PR gathers them into the
-- new "## x.y.z" section (scripts/changelog-gather.lua) and deletes them.

-- The issue number a fragment's file name gives ("256" for "256-part2.md"),
-- or nil when the name isn't a fragment's.
function Changelog.FragmentIssue(name)
    if type(name) ~= "string" then return nil end
    local issue = name:match("^([1-9]%d*)%.md$") or name:match("^([1-9]%d*)%-[a-z0-9][a-z0-9-]*%.md$")
    return tonumber(issue)
end

-- What is wrong with a fragment, as a message for the developer, or nil when
-- it is fine. text is the file's contents, nil when it couldn't be read. A
-- fragment is one changelog entry: one top-level "- " bullet (it may wrap and
-- have indented sub-bullets), tagged as every entry is, with the tag naming
-- the file's issue.
function Changelog.FragmentProblem(name, text)
    local where = "changes/" .. tostring(name)
    local issue = Changelog.FragmentIssue(name)
    if not issue then
        return where .. ": not a fragment; name it changes/<issue>.md (or <issue>-<word>.md), holding one bullet"
    end
    if type(text) ~= "string" then return where .. ": can't be read as a file" end
    local lines = Changelog.Lines(text)
    while lines[1] and not lines[1]:match("%S") do table.remove(lines, 1) end
    while lines[#lines] and not lines[#lines]:match("%S") do table.remove(lines) end
    if #lines == 0 then return where .. ": empty; it needs one bullet ending with its issue, e.g. (#" .. issue .. ")" end
    if not lines[1]:match("^%- %S") then return where .. ": must start with a bullet, \"- \"" end
    for _, line in ipairs(lines) do
        if not line:match("%S") then return where .. ": a blank line splits it; it holds one bullet" end
        if line:match("^ ? ? ?#+[ \t]") or line:match("^ ? ? ?#+$") then
            return where .. ": no headings; it holds one bullet"
        end
    end
    local entries = Changelog.Entries(lines)
    if #entries ~= 1 then return where .. ": holds " .. #entries .. " bullets; one change, one fragment" end
    local tagged = Changelog.TagIssues(entries[1].text)
    if not tagged or not Changelog.TagIssues(entries[1].last) then
        return where .. ": the bullet must end with its issue(s), e.g. (#" .. issue .. ") or (#" .. issue .. ", #52)"
    end
    for _, number in ipairs(tagged) do
        if number == issue then return nil end
    end
    return where .. ": its tag must include #" .. issue .. ", the issue in its name"
end

-- The fragments in gathering order: by issue number, then by name.
function Changelog.SortFragments(fragments)
    local sorted = {}
    for i, fragment in ipairs(fragments) do sorted[i] = fragment end
    table.sort(sorted, function(a, b)
        local x, y = Changelog.FragmentIssue(a.name) or math.huge, Changelog.FragmentIssue(b.name) or math.huge
        if x ~= y then return x < y end
        return a.name < b.name
    end)
    return sorted
end

-- The changelog with a new "## <version>" section at the top: the bullets
-- left under "### Unreleased" (which goes), as written, then each fragment's
-- bullet in gathering order. fragments is a list of { name, text }. Returns
-- the new text, or nil and a message (every problem found, one per line).
function Changelog.Gather(text, version, fragments)
    local problems = {}
    if type(version) ~= "string" or not version:match("^%d+%.%d+%.%d+$") then
        problems[#problems + 1] = "the version must look like 1.2.3, not " .. tostring(version)
    end
    for _, fragment in ipairs(fragments or {}) do
        problems[#problems + 1] = Changelog.FragmentProblem(fragment.name, fragment.text)
    end
    local lines = Changelog.Lines(text)
    if type(text) ~= "string" or text == "" then problems[#problems + 1] = "the changelog is empty" end
    if Changelog.CountHeading(text, "### Unreleased") > 1 then
        problems[#problems + 1] = "the changelog has more than one ### Unreleased heading; merge them first"
    end
    local newest
    for _, line in ipairs(lines) do
        local heading = Heading(line)
        if heading and heading:match("^## ") then newest = heading:sub(4); break end
    end
    if #problems == 0 and newest and not Changelog.IsLater(version, newest) then
        problems[#problems + 1] = ("%s must come after the newest release in the changelog, %s"):format(version, newest)
    end
    local leftover = {}
    local unreleased = Changelog.Section(text, "### Unreleased") or {}
    for _, line in ipairs(unreleased) do leftover[#leftover + 1] = line end
    while leftover[1] and not leftover[1]:match("%S") do table.remove(leftover, 1) end
    while leftover[#leftover] and not leftover[#leftover]:match("%S") do table.remove(leftover) end
    local section = {}
    for _, line in ipairs(leftover) do section[#section + 1] = line end
    for _, fragment in ipairs(Changelog.SortFragments(fragments or {})) do
        for _, line in ipairs(Changelog.Lines(fragment.text)) do
            if line:match("%S") then section[#section + 1] = (line:gsub("%s+$", "")) end
        end
    end
    if #section == 0 then problems[#problems + 1] = "nothing to release: no fragments and no ### Unreleased bullets" end
    if #problems > 0 then return nil, table.concat(problems, "\n") end

    -- Everything above the first section stays; the Unreleased section is
    -- replaced; the new section goes before the newest release.
    local out, placed, skipping = {}, false, false
    local function place()
        out[#out + 1] = "## " .. version
        out[#out + 1] = ""
        for _, line in ipairs(section) do out[#out + 1] = line end
        out[#out + 1] = ""
        placed = true
    end
    for _, line in ipairs(lines) do
        local heading = Heading(line)
        if skipping and StartsSection(line) then skipping = false end
        if not placed and heading == "### Unreleased" then
            place()
            skipping = true
        elseif not placed and heading and heading:match("^## ") then
            place()
            out[#out + 1] = line
        elseif not skipping then
            out[#out + 1] = line
        end
    end
    if not placed then
        if out[#out] == "" then table.remove(out) end
        out[#out + 1] = ""
        place()
    end
    while out[#out] == "" do table.remove(out) end
    return table.concat(out, "\n") .. "\n"
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
