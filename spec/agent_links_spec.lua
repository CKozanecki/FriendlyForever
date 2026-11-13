-- Spec: #263
-- Every relative link in the skills and the agent files must resolve to an
-- existing file, and its #anchor to an existing heading, with the slugs GitHub
-- makes. A link one folder too shallow once sat in the coordinator skill
-- unseen (#263).
local wow = require("spec.support.wow")

local function splitLines(text)
    local list = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do list[#list + 1] = (line:gsub("\r$", "")) end
    return list
end

local function exists(path)
    local f = io.open(path, "r")
    if f then f:close() end
    return f ~= nil
end

-- GitHub's heading slug: markup out, lower case, punctuation out (but - and _
-- stay), spaces to hyphens.
local function slug(heading)
    local s = heading:gsub("`", ""):gsub("%[([^%]]*)%]%([^)]*%)", "%1"):gsub("[%*~]", "")
    s = s:lower():gsub("[^%w%s%-_\128-\255]", ""):gsub("%s", "-")
    return s
end

-- The anchors of a document, in order, with GitHub's -1, -2 for repeats.
local function anchorsOf(text)
    local anchors, seen, fenced = {}, {}, false
    for _, line in ipairs(splitLines(text)) do
        if line:match("^%s*```") or line:match("^%s*~~~") then
            fenced = not fenced
        elseif not fenced then
            local heading = line:match("^ ? ? ?#+%s+(.-)%s*#*%s*$")
            if heading then
                local base = slug(heading)
                local n = seen[base]
                anchors[n and (base .. "-" .. n) or base] = true
                seen[base] = (n or 0) + 1
            end
        end
    end
    return anchors
end

-- Every relative link of a document: { line, target, file, anchor }.
local function linksOf(text)
    local links, fenced = {}, false
    for number, line in ipairs(splitLines(text)) do
        if line:match("^%s*```") or line:match("^%s*~~~") then
            fenced = not fenced
        elseif not fenced then
            local bare = line:gsub("`[^`]*`", "")
            for target in bare:gmatch("%[[^%]]*%]%(([^%s)]+)[^)]*%)") do
                if not target:match("^%a[%w+.-]*:") then
                    local file, anchor = target:match("^([^#]*)#?(.*)$")
                    links[#links + 1] = { line = number, target = target, file = file, anchor = anchor }
                end
            end
        end
    end
    return links
end

local function dirOf(path) return path:match("^(.*)/[^/]*$") or "." end

-- Normalises a/b/../c to a/c, so messages and lookups are plain; nil if it
-- climbs out of the root.
local function normalise(path)
    local parts = {}
    for part in path:gmatch("[^/]+") do
        if part == ".." then
            if #parts == 0 then return nil end
            parts[#parts] = nil
        elseif part ~= "." then
            parts[#parts + 1] = part
        end
    end
    return table.concat(parts, "/")
end

-- The broken links of one document, as messages naming file and line.
-- read(path) returns a file's text or nil; it is injected for the tests.
local function brokenLinks(path, text, read)
    local broken = {}
    for _, link in ipairs(linksOf(text)) do
        local target = link.file == "" and path or normalise(dirOf(path) .. "/" .. link.file)
        local where = path .. ":" .. link.line .. ": " .. link.target
        local body = target and read(target)
        if not body then
            broken[#broken + 1] = where .. " doesn't resolve to a file"
        elseif link.anchor ~= "" and target:match("%.md$") and not anchorsOf(body)[link.anchor:lower()] then
            broken[#broken + 1] = where .. " has no such heading"
        end
    end
    return broken
end

local function listFiles()
    local p = io.popen('cd "' .. wow.ROOT .. '" && ls .claude/skills/*/SKILL.md .claude/agents/*.md')
    local files = {}
    for line in p:lines() do files[#files + 1] = line end
    p:close()
    return files
end

local function readFromRoot(path)
    if not exists(wow.ROOT .. "/" .. path) then return nil end
    return wow.readFile(path)
end

describe("relative links in the skills and agent files", function()
    it("all resolve to an existing file and heading", function()
        local files = listFiles()
        assert.is_true(#files >= 5, "found the skill and agent files")
        for _, path in ipairs(files) do
            local broken = brokenLinks(path, wow.readFile(path), readFromRoot)
            assert.are.same({}, broken)
        end
    end)

    it("fail on a link one folder too shallow, naming file and line", function()
        local docs = { ["CONTRIBUTING.md"] = "# Top\n\n## Only behind `main`\n" }
        local read = function(p) return docs[p] end
        local text = "x\nsee [r](../../CONTRIBUTING.md#only-behind-main)\n"
        assert.are.same({ ".claude/skills/a/SKILL.md:2: ../../CONTRIBUTING.md#only-behind-main doesn't resolve to a file" },
            brokenLinks(".claude/skills/a/SKILL.md", text, read))
        assert.are.same({}, brokenLinks(".claude/skills/a/SKILL.md",
            "see [r](../../../CONTRIBUTING.md#only-behind-main)", read))
    end)

    it("fail on a missing anchor, and a missing local one", function()
        local docs = { ["CONTRIBUTING.md"] = "## Review loops\n" }
        local text = "[a](../../CONTRIBUTING.md#review-loop)\n[b](#nowhere)\n"
        local broken = brokenLinks("a/b/c.md", text, function(p) return p == "a/b/c.md" and "# Top\n" or docs[p] end)
        assert.are.same({ "a/b/c.md:1: ../../CONTRIBUTING.md#review-loop has no such heading",
            "a/b/c.md:2: #nowhere has no such heading" }, broken)
    end)

    it("make anchors the way GitHub does", function()
        local anchors = anchorsOf("# A\n## Only behind `main`\n## Review loops\n## Review loops\n"
            .. "```\n# not a heading\n```\n### Who's [here](x.md) *now*?\n")
        for _, a in ipairs({ "a", "only-behind-main", "review-loops", "review-loops-1", "whos-here-now" }) do
            assert.is_true(anchors[a] == true, a)
        end
        assert.is_nil(anchors["not-a-heading"])
    end)

    it("skip web links, code spans and fenced blocks", function()
        local text = "[w](https://x.org/a#b) `[c](nope.md)`\n```\n[d](nope.md)\n```\n"
        assert.are.same({}, brokenLinks("a.md", text, function() return nil end))
    end)
end)
