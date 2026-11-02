-- Spec: #187
-- The CI trailer check (scripts/check-trailers.sh): each product's commits
-- stay on its own branches. Each test builds a throwaway git repository and
-- runs the script on it the way CI does.
local wow = require("spec.support.wow")

-- The tests run the script from inside a throwaway repository, so its path
-- must be absolute.
local function absolute(path)
    if path:sub(1, 1) == "/" then return path end
    local p = io.popen("pwd")
    local cwd = p:read("*l")
    p:close()
    return cwd .. "/" .. path
end
local SCRIPT = absolute(wow.ROOT .. "scripts/check-trailers.sh")
local CLAUDE = "Claude-Session: https://claude.ai/code/session_x"
local CODEX = "Agent: codex sol"

-- Quotes a value for the shell, so the tests' own commands can't be injected.
local function q(text) return "'" .. tostring(text):gsub("'", "'\\''") .. "'" end

local function run(dir, cmd)
    local p = io.popen("cd " .. q(dir) .. " && { " .. cmd .. "\n} 2>&1; echo \"exit=$?\"")
    local out = p:read("*a")
    p:close()
    return out:gsub("exit=(%d+)\n$", ""), tonumber(out:match("exit=(%d+)\n$"))
end

local function newRepo()
    local dir = os.tmpname()
    os.remove(dir)
    local _, code = run("/", "mkdir " .. q(dir) .. " && cd " .. q(dir) .. " && git init -q -b main"
        .. " && git config user.email t@example.com && git config user.name t && git config commit.gpgsign false"
        .. " && echo base > f && git add f && git commit -q -m base")
    assert.are.equal(0, code)
    return dir
end

-- Commits a change to a file (f unless named) with the given message on the
-- current branch.
local n = 0
local function commit(dir, message, file)
    n = n + 1
    file = file or "f"
    local _, code = run(dir, "echo " .. n .. " >> " .. file .. " && git add " .. file
        .. " && git commit -q -F - <<'MSG'\n" .. message .. "\nMSG")
    assert.are.equal(0, code)
end

local function check(dir, branch, base)
    return run(dir, q(SCRIPT) .. " " .. q(base or "main") .. " HEAD " .. q(branch))
end

describe("the agent trailer check", function()
    local dir
    before_each(function() dir = newRepo() end)
    after_each(function() os.execute("rm -rf " .. q(dir)) end)

    it("passes a claude/ PR whose commits all carry the Claude trailer", function()
        run(dir, "git checkout -q -b claude/1-x")
        commit(dir, "One\n\n" .. CLAUDE)
        commit(dir, "Two\n\nBody.\n\nCo-Authored-By: Claude <noreply@anthropic.com>\n" .. CLAUDE)
        local out, code = check(dir, "claude/1-x")
        assert.are.equal(0, code, out)
        assert.is_truthy(out:find("Checked 2 commit(s) on a claude/ branch", 1, true), out)
    end)

    it("passes a codex/ PR whose commits all carry the Codex trailer", function()
        run(dir, "git checkout -q -b codex/1-x")
        commit(dir, "One\n\n" .. CODEX)
        commit(dir, "Two\n\nagent: codex terra")
        local out, code = check(dir, "codex/1-x")
        assert.are.equal(0, code, out)
        assert.is_truthy(out:find("Checked 2 commit(s) on a codex/ branch", 1, true), out)
    end)

    it("exempts a merge of main, but checks the PR's own commits around it", function()
        run(dir, "git checkout -q -b claude/1-x")
        commit(dir, "One\n\n" .. CLAUDE)
        run(dir, "git checkout -q main")
        commit(dir, "Someone else's PR (#9)", "g")
        local _, merged = run(dir, "git checkout -q claude/1-x && git merge -q --no-edit main")
        assert.are.equal(0, merged)
        local out, code = check(dir, "claude/1-x")
        assert.are.equal(0, code, out)
        assert.is_truthy(out:find("Checked 1 commit(s)", 1, true), out)
        commit(dir, "Two, no trailer")
        out, code = check(dir, "claude/1-x")
        assert.are.equal(1, code, out)
    end)

    it("leaves branches without an agent prefix alone", function()
        run(dir, "git checkout -q -b 57-owner-fix")
        commit(dir, "No trailer")
        local out, code = check(dir, "57-owner-fix")
        assert.are.equal(0, code, out)
        assert.is_truthy(out:find("nothing to check", 1, true), out)
    end)

    describe("fails", function()
        it("a commit without the Claude trailer on claude/*", function()
            run(dir, "git checkout -q -b claude/1-x")
            commit(dir, "One\n\n" .. CLAUDE)
            commit(dir, "Two\n\nCo-Authored-By: someone")
            local out, code = check(dir, "claude/1-x")
            assert.are.equal(1, code, out)
            assert.is_truthy(out:find("on a claude/ branch has no Claude-Session: trailer", 1, true), out)
        end)

        it("a Claude-Session line in the body only, not the trailer block, on claude/*", function()
            run(dir, "git checkout -q -b claude/1-x")
            commit(dir, "One\n\n" .. CLAUDE .. "\n\nA last paragraph that isn't trailers.")
            local _, code = check(dir, "claude/1-x")
            assert.are.equal(1, code)
        end)

        it("an empty Claude-Session trailer on claude/*", function()
            run(dir, "git checkout -q -b claude/1-x")
            commit(dir, "One\n\nClaude-Session:")
            local _, code = check(dir, "claude/1-x")
            assert.are.equal(1, code)
        end)

        it("a Codex-trailered commit on claude/*", function()
            run(dir, "git checkout -q -b claude/1-x")
            commit(dir, "One\n\n" .. CLAUDE .. "\n" .. CODEX)
            local out, code = check(dir, "claude/1-x")
            assert.are.equal(1, code, out)
            assert.is_truthy(out:find("carries an Agent: codex trailer", 1, true), out)
        end)

        it("a commit without the Codex trailer on codex/*", function()
            for _, message in ipairs({ "One", "One\n\nAgent: codex", "One\n\nAgent: claude opus",
                "One\n\nAgent: codexsol" }) do
                run(dir, "git checkout -q main && git checkout -q -B codex/1-x")
                commit(dir, message)
                local out, code = check(dir, "codex/1-x")
                assert.are.equal(1, code, message .. "\n" .. out)
                assert.is_truthy(out:find("has no 'Agent: codex <model>' trailer", 1, true), out)
            end
        end)

        it("a Claude-trailered commit on codex/*", function()
            for _, message in ipairs({ "One\n\n" .. CODEX .. "\n" .. CLAUDE,
                "One\n\n" .. CLAUDE .. "\n\n" .. CODEX, "One\n\nclaude-session: x\n" .. CODEX }) do
                run(dir, "git checkout -q main && git checkout -q -B codex/1-x")
                commit(dir, message)
                local out, code = check(dir, "codex/1-x")
                assert.are.equal(1, code, message .. "\n" .. out)
                assert.is_truthy(out:find("on a codex/ branch carries a Claude-Session: line", 1, true), out)
            end
        end)

        it("a merge that isn't of main, checked like a commit", function()
            run(dir, "git checkout -q -b side")
            commit(dir, "Side work, no trailer", "g")
            run(dir, "git checkout -q main && git checkout -q -b claude/1-x")
            commit(dir, "One\n\n" .. CLAUDE)
            local _, merged = run(dir, "git merge -q --no-edit side")
            assert.are.equal(0, merged)
            local out, code = check(dir, "claude/1-x")
            assert.are.equal(1, code, out)
            local _, failures = out:gsub("has no Claude%-Session: trailer", "")
            assert.are.equal(2, failures, out)
        end)
    end)

    it("treats a commit message built to inject shell as text", function()
        local marker = dir .. "/pwned"
        run(dir, "git checkout -q -b claude/1-x")
        for _, evil in ipairs({ "$(touch " .. marker .. ")", "`touch " .. marker .. "`",
            "'; touch " .. marker .. "; '", "\"; touch " .. marker .. "; \"", "::error::forged" }) do
            commit(dir, evil .. "\n\nClaude-Session: " .. evil)
            commit(dir, evil .. "\n\n" .. "Co-Authored-By: " .. evil)
        end
        local out, code = check(dir, "claude/1-x")
        assert.are.equal(1, code, out)
        assert.is_nil(io.open(marker), "a commit message ran a command")
        assert.is_falsy(out:find("forged", 1, true), "a commit message reached the log")
        local _, failures = out:gsub("has no Claude%-Session: trailer", "")
        assert.are.equal(5, failures, out)
    end)

    it("treats a branch name built to inject shell as text", function()
        local marker = dir .. "/pwned"
        for _, branch in ipairs({ "claude/$(touch " .. marker .. ")", "codex/`touch " .. marker .. "`" }) do
            local out, code = check(dir, branch, "HEAD")
            assert.are.equal(0, code, out)
        end
        assert.is_nil(io.open(marker), "a branch name ran a command")
    end)

    it("refuses a base or head that isn't a commit", function()
        local _, code = run(dir, q(SCRIPT) .. " nope HEAD claude/1-x")
        assert.are.equal(2, code)
        _, code = run(dir, q(SCRIPT) .. " main")
        assert.are.equal(2, code)
    end)
end)
