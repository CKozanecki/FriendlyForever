-- Gathers the changelog fragments into the release's section (#261).
--
-- Between releases each pull request adds its note as changes/<issue>.md.
-- The release PR runs this once: it writes "## <version>" at the top of
-- CHANGELOG.md with the bullets left under "### Unreleased" (as written),
-- then every fragment's bullet by issue number, and deletes the fragments.
-- It checks every fragment first and changes nothing if any is wrong.
--
-- Usage (from the repo, with make setup's Lua):
--   make changelog VERSION=1.1.0           gather and delete the fragments
--   make changelog-preview VERSION=1.1.0   print the new section, change nothing
-- or: lua scripts/changelog-gather.lua [--dry-run] <version> [changelog] [changes dir]
--
-- The parsing is spec/support/changelog.lua's, the same code the repo tests
-- check the changelog and the fragments with.

local here = (debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$")) or "."
local Changelog = dofile(here .. "/../spec/support/changelog.lua")

local Gather = {}

local function readFile(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local text = file:read("*a")
    file:close()
    return text
end

local function quote(path) return "'" .. path:gsub("'", "'\\''") .. "'" end

-- The names in a folder (hidden ones too), or an empty list when it doesn't
-- exist: after a release there are no fragments and no folder.
function Gather.ListDir(dir)
    local names = {}
    local pipe = io.popen("ls -A " .. quote(dir) .. " 2>/dev/null")
    for name in pipe:read("*a"):gmatch("[^\n]+") do names[#names + 1] = name end
    pipe:close()
    table.sort(names)
    return names
end

-- The fragments in a folder, each { name, text }, with text nil for
-- anything that can't be read as a file (a folder, say).
function Gather.ReadFragments(dir)
    local fragments = {}
    for _, name in ipairs(Gather.ListDir(dir)) do
        fragments[#fragments + 1] = { name = name, text = readFile(dir .. "/" .. name) }
    end
    return fragments
end

-- The section Gather wrote: from its heading to the next release's.
local function newSection(text, version)
    local lines = Changelog.Section(text, "## " .. version) or {}
    while lines[#lines] == "" do table.remove(lines) end
    return "## " .. version .. "\n" .. table.concat(lines, "\n") .. "\n"
end

-- Runs the command; argv as the command line gives it. Prints to out and
-- err (functions taking a line) and returns the exit code.
function Gather.Main(argv, out, err)
    out = out or print
    err = err or function(line) io.stderr:write(line, "\n") end
    local dry = argv[1] == "--dry-run"
    local args = {}
    for i = dry and 2 or 1, #argv do args[#args + 1] = argv[i] end
    local version, changelogPath = args[1], args[2] or (here .. "/../CHANGELOG.md")
    local changesDir = args[3] or (here .. "/../changes")
    if not version or #args > 3 then
        err("usage: changelog-gather.lua [--dry-run] <version> [changelog] [changes dir]")
        return 2
    end
    local text = readFile(changelogPath)
    if not text then
        err("can't read " .. changelogPath)
        return 1
    end
    local fragments = Gather.ReadFragments(changesDir)
    local gathered, problem = Changelog.Gather(text, version, fragments)
    if not gathered then
        err("Nothing changed:\n" .. problem)
        return 1
    end
    if dry then
        out("Dry run: CHANGELOG.md would start its " .. version .. " section with:")
        out("")
        out(newSection(gathered, version))
        for _, fragment in ipairs(Changelog.SortFragments(fragments)) do
            out("would delete changes/" .. fragment.name)
        end
        return 0
    end
    -- Write beside the changelog and move it into place, so it is never
    -- left half written (#178), then delete the fragments it now holds.
    local tmp = changelogPath .. ".gather"
    local file = io.open(tmp, "wb")
    if not file then
        err("can't write " .. tmp)
        return 1
    end
    file:write(gathered)
    file:close()
    local moved, why = os.rename(tmp, changelogPath)
    if not moved then
        os.remove(tmp)
        err("can't replace " .. changelogPath .. ": " .. tostring(why))
        return 1
    end
    for _, fragment in ipairs(fragments) do
        local removed, reason = os.remove(changesDir .. "/" .. fragment.name)
        if not removed then
            err("gathered, but couldn't delete changes/" .. fragment.name .. ": " .. tostring(reason))
            return 1
        end
        out("gathered and deleted changes/" .. fragment.name)
    end
    out(changelogPath .. ": " .. version .. " section written")
    return 0
end

if ... == "--module" then return Gather end
os.exit(Gather.Main({ ... }))
