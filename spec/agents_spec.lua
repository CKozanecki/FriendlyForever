-- Spec: #186
-- The drift check for the agents' instruction files. AGENTS.md holds the rules
-- every product follows; CLAUDE.md imports it and adds only Claude's own.
-- Codex reads AGENTS.md (or an AGENTS.override.md, which Claude never reads)
-- up to a size cap. See docs/agent-facts.md for the sources.
local wow = require("spec.support.wow")

-- Codex's project_doc_max_bytes default (docs/agent-facts.md).
local CODEX_MAX_BYTES = 32 * 1024

local function splitLines(text)
    local list = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do list[#list + 1] = (line:gsub("\r$", "")) end
    return list
end

-- The headings of AGENTS.md's safety section: the section's own, and each
-- rule's bold label, such as "Casting:" or "The owner merges.".
local function safetyHeadings(agents)
    local headings, inSection = {}, false
    for _, line in ipairs(splitLines(agents)) do
        local heading = line:match("^##%s+(.-)%s*$")
        if heading then
            inSection = heading == "Standards and safety"
            if inSection then headings[#headings + 1] = heading end
        elseif inSection then
            local label = line:match("^%- %*%*(.-)%*%*")
            if label then headings[#headings + 1] = label end
        end
    end
    return headings
end

-- What's wrong with the pair, as a list. overrides lists every
-- AGENTS.override.md found in the tree.
local function driftProblems(claude, agents, overrides)
    local problems = {}
    local imported = false
    for _, line in ipairs(splitLines(claude)) do
        if line:match("^@AGENTS%.md%s*$") then imported = true end
    end
    if not imported then problems[#problems + 1] = "CLAUDE.md doesn't import @AGENTS.md" end

    local headings = safetyHeadings(agents)
    if #headings < 2 then problems[#problems + 1] = "AGENTS.md has no Standards and safety rules" end
    for at, heading in ipairs(headings) do
        local repeated
        if at == 1 then
            for _, line in ipairs(splitLines(claude)) do
                local title = line:match("^#+%s+(.-)%s*$")
                if title and title:lower() == heading:lower() then repeated = true end
            end
        else
            repeated = claude:find("**" .. heading .. "**", 1, true)
        end
        if repeated then problems[#problems + 1] = "CLAUDE.md repeats AGENTS.md's safety heading: " .. heading end
    end

    for _, path in ipairs(overrides) do problems[#problems + 1] = "AGENTS.override.md exists: " .. path end

    if #agents > CODEX_MAX_BYTES then
        problems[#problems + 1] = ("AGENTS.md is %d bytes, over Codex's cap of %d"):format(#agents, CODEX_MAX_BYTES)
    end
    return problems
end

-- Every AGENTS.override.md under root, tracked or not. Other sessions'
-- worktrees in .claude/worktrees are checkouts of their own, checked there.
local function findOverrides(root)
    local found = {}
    local p = io.popen('cd "' .. root .. '" && find . -path ./.git -prune -o -path ./.claude/worktrees -prune'
        .. ' -o -name AGENTS.override.md -print')
    for line in p:read("*a"):gmatch("[^\n]+") do found[#found + 1] = line end
    p:close()
    return found
end

describe("the agents' instruction files", function()
    local claude = wow.readFile("CLAUDE.md")
    local agents = wow.readFile("AGENTS.md")

    it("pass the drift check: CLAUDE.md imports AGENTS.md, repeats no safety heading, no override, under the cap",
        function()
            assert.are.same({}, driftProblems(claude, agents, findOverrides(wow.ROOT)))
        end)

    it("AGENTS.md holds the shared rules, the handoff format and the Codex notes", function()
        for _, heading in ipairs({ "Start here", "Standards and safety", "Shared knowledge", "Starting and stopping",
            "Issues and specs", "Pull requests", "Several sessions at once", "Reviews", "Tests", "Codex" }) do
            assert.is_truthy(agents:find("\n## " .. heading .. "\n", 1, true), heading)
        end
        assert.is_truthy(agents:find("### Handoff · <product> <model as served> · <UTC time>\n"
            .. "  - State: done | partial | blocked\n  - Branch / commit / PR:\n  - Done:\n  - Left:\n"
            .. "  - Next session must know:\n", 1, true), "the handoff format")
        assert.is_truthy(agents:find("**[CONTRIBUTING.md](CONTRIBUTING.md) is the source of truth.**", 1, true))
        assert.is_truthy(agents:find("Codex's carry `Agent: codex <model as served>`, and never a"
            .. " `Claude-Session:` line.", 1, true), "the Codex trailer")
    end)

    it("CLAUDE.md keeps only Claude's own sections", function()
        local sections = {}
        for heading in claude:gmatch("\n## ([^\n]*)") do sections[#sections + 1] = heading end
        assert.are.same({ "Agents and skills", "Coordinating sessions", "Plan limits", "Models and effort",
            "Review records" }, sections)
    end)

    describe("the drift check fails", function()
        local overrides = {}

        it("when CLAUDE.md doesn't import AGENTS.md", function()
            for _, text in ipairs({
                (claude:gsub("\n@AGENTS%.md\n", "\n\n")),
                (claude:gsub("\n@AGENTS%.md\n", "\nSee @AGENTS.md for the rules.\n")),
                (claude:gsub("\n@AGENTS%.md\n", "\n@AGENTS.md.bak\n")),
            }) do
                assert.are_not.equal(claude, text)
                assert.are.same({ "CLAUDE.md doesn't import @AGENTS.md" }, driftProblems(text, agents, overrides))
            end
        end)

        it("when a safety heading from AGENTS.md appears again in CLAUDE.md", function()
            local headings = safetyHeadings(agents)
            assert.is_true(#headings >= 10, "found " .. #headings .. " safety headings")
            for at, heading in ipairs(headings) do
                local copies = at == 1 and { "\n## " .. heading:upper() .. "\n", "\n### " .. heading .. "\n",
                    "\n# " .. heading .. "  \n" } or { "\n- **" .. heading .. "** copied.\n" }
                for _, copy in ipairs(copies) do
                    assert.are.same({ "CLAUDE.md repeats AGENTS.md's safety heading: " .. heading },
                        driftProblems(claude .. copy, agents, overrides), copy)
                end
            end
        end)

        it("when AGENTS.md loses its safety section", function()
            local stripped = agents:gsub("\n## Standards and safety\n", "\n## Safety notes\n")
            assert.are.same({ "AGENTS.md has no Standards and safety rules" },
                driftProblems(claude, stripped, overrides))
        end)

        it("when an AGENTS.override.md exists anywhere in the repo", function()
            local root = os.tmpname()
            os.remove(root)
            assert.is_true(os.execute('mkdir -p "' .. root .. '/a/b" "' .. root .. '/.git/x"') == 0)
            assert.are.same({}, findOverrides(root))
            for _, path in ipairs({ "a/b/AGENTS.override.md", ".git/x/AGENTS.override.md" }) do
                local f = assert(io.open(root .. "/" .. path, "w"))
                f:write("override\n")
                f:close()
            end
            local found = findOverrides(root)
            os.execute('rm -rf "' .. root .. '"')
            assert.are.same({ "./a/b/AGENTS.override.md" }, found)
            assert.are.same({ "AGENTS.override.md exists: ./a/b/AGENTS.override.md" },
                driftProblems(claude, agents, found))
        end)

        -- The cap is written out here, and read from docs/agent-facts.md, so
        -- neither the constant nor the recorded source can move alone.
        it("when AGENTS.md is over Codex's size cap of 32768 bytes, as docs/agent-facts.md records", function()
            local facts = wow.readFile("docs/agent-facts.md")
            assert.are.equal("32768", facts:match("32 KiB %((%d+) bytes%)"))
            assert.is_truthy(facts:find("fails if `AGENTS.md` is over 32768 bytes", 1, true))
            local padded = agents .. ("x"):rep(32768 - #agents)
            assert.are.equal(32768, #padded)
            assert.are.same({}, driftProblems(claude, padded, overrides))
            assert.are.same({ "AGENTS.md is 32769 bytes, over Codex's cap of 32768" },
                driftProblems(claude, padded .. "x", overrides))
        end)
    end)
end)
