-- Spec: #183, #186, #217, #237
-- The drift check for the agents' instruction files. AGENTS.md holds the rules
-- every product follows; CLAUDE.md imports it and adds only Claude's own.
-- Codex reads AGENTS.md (or an AGENTS.override.md, which Claude never reads)
-- up to a size cap. The Codex trial is paused (#183, 2026-11-14), and these
-- checks stay so it can restart without rework. See docs/agent-facts.md.
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

    it("AGENTS.md holds the shared rules and the handoff format, and no Codex-only rules while the trial is paused (#183)", function()
        for _, heading in ipairs({ "Start here", "Standards and safety", "Shared knowledge", "Starting and stopping",
            "Issues and specs", "Pull requests", "Several sessions at once", "Reviews", "Tests" }) do
            assert.is_truthy(agents:find("\n## " .. heading .. "\n", 1, true), heading)
        end
        assert.is_falsy(agents:find("\n#+%s*Codex%s*\n"), "no Codex section, at any heading level, while the trial is paused")
        assert.is_truthy(agents:find("### Handoff · <product> <model as served> · <UTC time>\n"
            .. "  - State: done | partial | blocked\n  - Branch / commit / PR:\n  - Done:\n  - Left:\n"
            .. "  - Next session must know:\n", 1, true), "the handoff format")
        assert.is_truthy(agents:find("**[CONTRIBUTING.md](CONTRIBUTING.md) is the source of truth.**", 1, true))
        assert.is_truthy(agents:find("the Codex trial is paused", 1, true), "the pause is recorded")
        assert.is_falsy(agents:find("Agent: codex", 1, true), "no Codex commit trailer")
        assert.is_falsy(agents:find("codex/", 1, true), "no codex/ branch rule, however it is written")
        assert.is_falsy(claude:find("AGENTS.md's \"Codex\"", 1, true), "CLAUDE.md points to no Codex section")
        assert.is_truthy(agents:find("name each one `claude/<issue>-<what-it-does>`", 1, true), "the branch prefix")
    end)

    it("AGENTS.md records the owner's word about the game as fact, never hedged (#237)", function()
        assert.is_truthy(agents:find("**The owner's word about the game is a fact.** Record it as a fact, with the owner"
            .. " as the source. Never write \"the owner believes\", \"on the owner's belief\" or a similar hedge in"
            .. " player-facing text or docs.", 1, true))
        assert.is_truthy(agents:find("checks the official patch notes first and tells the coordinator before writing"
            .. " anything public; it doesn't ask the owner to prove it and doesn't publish the doubt", 1, true))
        local _, count = agents:gsub("The owner's word about the game is a fact", "")
        assert.are.equal(1, count)
        assert.is_falsy(claude:find("word about the game is a fact", 1, true), "written once, not repeated in CLAUDE.md")
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

-- The two review-saving rules (#217) are written once, in CONTRIBUTING.md,
-- and every other rule file points there instead of restating them.
describe("the review-saving rules", function()
    local function flat(path) return (wow.readFile(path):gsub("%s+", " ")) end
    local contributing = flat("CONTRIBUTING.md")
    local LINK = "CONTRIBUTING.md#review-loops"

    it("are written once in CONTRIBUTING.md, with the proof and the exceptions", function()
        for _, text in ipairs({
            "**A merge that touches none of the PR's files: CI only.**",
            "`git diff --name-only <old main>..<new main>`",
            "`git diff --name-only origin/main...HEAD`",
            "If the merge was clean (no conflict resolved) and the lists share no file",
            "puts both lists in the description",
            "The reviewers don't confirm.",
            "If any file is in both lists, or a conflict was resolved, the reviewers confirm the merge and the"
                .. " resolution only",
            "**A docs-only pull request: CI plus one review.**",
            "the `lua-architect` and `lua-tester` files run as a single pass",
            "It has no mutation pass and no second loop.",
            "Any `*.lua` change outside comments, any `*.toc` or `*.xml` change and any workflow file is never"
                .. " docs-only",
            "a code PR still gets both review loops once",
            "An approved review is never repeated",
            "**Mutation checks are for safety-critical code only (#217).**",
            "code where a mistake could cast wrongly, mishandle a secret value, or damage saved settings",
            "The testing reviewer checks that list and the tests, and doesn't repeat the list",
            "3 to 5 targeted mutations of its own",
            "A merge confirmation mutates only the lines the merge changed or resolved.",
        }) do
            local _, count = contributing:gsub(text:gsub("%p", "%%%0"), "")
            assert.are.equal(1, count, text)
        end
    end)

    it("are referenced, not restated, by the rules, skills and agent files", function()
        for _, path in ipairs({ "AGENTS.md", ".claude/skills/after-merge/SKILL.md",
            ".claude/skills/coordinator/SKILL.md", ".claude/agents/lua-architect.md",
            ".claude/agents/lua-tester.md" }) do
            local text = flat(path)
            assert.is_truthy(text:find(LINK, 1, true), path .. " doesn't point to the rules")
            assert.is_falsy(text:find("A docs-only pull request: CI plus one review", 1, true), path .. " restates")
            assert.is_falsy(text:find("A merge that touches none of the PR's files: CI only", 1, true), path .. " restates")
        end
    end)

    it("define safety-critical code once, and AGENTS.md, the tester and the PR template point there", function()
        for _, path in ipairs({ "AGENTS.md", ".claude/agents/lua-tester.md", ".github/pull_request_template.md" }) do
            local text = flat(path)
            assert.is_truthy(text:find("CONTRIBUTING.md#review-loops", 1, true), path)
            assert.is_truthy(text:find("safety-critical", 1, true), path)
            assert.is_falsy(text:find("mishandle a secret value", 1, true), path .. " restates the definition")
        end
        assert.is_falsy(contributing:find("trivial conflict", 1, true), "no trivial-conflict exemption")
    end)

    it("have the skills say how to prove a merge is file-disjoint, and send overlaps and conflicts to the reviewers",
        function()
        for _, path in ipairs({ ".claude/skills/after-merge/SKILL.md", ".claude/skills/coordinator/SKILL.md" }) do
            local text = flat(path)
            assert.is_truthy(text:find("git diff --name-only <old main>..<new main>", 1, true), path)
            assert.is_truthy(text:find("git diff --name-only origin/main...HEAD", 1, true), path)
        end
        local afterMerge = flat(".claude/skills/after-merge/SKILL.md")
        assert.is_truthy(afterMerge:find("If a file is in both lists, or a conflict was resolved, the reviewers"
            .. " confirm the merge and the resolution only", 1, true))
        assert.is_truthy(flat("AGENTS.md"):find("the reviewers confirm the merge, unless it touches none of the PR's"
            .. " files", 1, true))
    end)

    it("never tell the testing reviewer to mutation-check every safety-critical line itself (#217)", function()
        local tester = flat(".claude/agents/lua-tester.md")
        assert.is_falsy(tester:find("Mutation-check every new or changed", 1, true))
        assert.is_falsy(tester:find("Run your own mutations only of the new safety-critical lines", 1, true))
        assert.is_falsy(tester:lower():find("mutate its lines too", 1, true))
        assert.is_truthy(tester:find("3 to 5 targeted mutations", 1, true))
        assert.is_truthy(tester:find("don't re-run the list", 1, true))
        assert.is_truthy(tester:find("developer's mutation list** from the PR", 1, true), "the tester is given the list")
        assert.is_truthy(flat("AGENTS.md"):find("change each new or changed line of it", 1, true))
        assert.is_truthy(flat(".claude/skills/after-merge/SKILL.md"):find("mutates only the lines the merge changed"
            .. " or resolved", 1, true))
        assert.is_truthy(flat("AGENTS.md"):find("mutates only the lines the merge changed or resolved", 1, true))
    end)
end)
