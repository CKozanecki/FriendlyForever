-- Spec: #103
-- Runs scripts/dev-setup.sh against local files instead of the real hosts:
-- DEV_SETUP_LOCK points it at a checksum file written here, and
-- DEV_SETUP_TEST lets that file use file:// URLs. Nothing here downloads.
local wow = require("spec.support.wow")

local SCRIPT = wow.ROOT .. "scripts/dev-setup.sh"
local LOCK = wow.ROOT .. "scripts/dev-setup.lock"

local function quote(text) return "'" .. text:gsub("'", "'\\''") .. "'" end

local function shell(command)
    local ok = os.execute(command)
    return ok == true or ok == 0
end

local function readAll(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local text = file:read("*a")
    file:close()
    return text
end

local function write(path, text)
    local file = assert(io.open(path, "wb"))
    file:write(text)
    file:close()
end

local function exists(path) return shell("test -e " .. quote(path)) end

local function sha256(path)
    local p = io.popen("(sha256sum " .. quote(path) .. " 2>/dev/null || shasum -a 256 " .. quote(path) .. ") | cut -d' ' -f1")
    local sum = p:read("*l")
    p:close()
    return sum
end

-- The files the real checksum file lists, in its order.
local function lockedNames()
    local names = {}
    for line in (readAll(LOCK) .. "\n"):gmatch("([^\n]*)\n") do
        local name = line:match("^([%w][%w._-]*)%s")
        if name then names[#names + 1] = name end
    end
    return names
end

describe("Toolchain setup script", function()
    local dir, tools, files

    before_each(function()
        dir = os.tmpname()
        os.remove(dir)
        tools, files = dir .. "/tools", dir .. "/files"
        assert(shell("mkdir -p " .. quote(tools) .. " " .. quote(files)))
    end)

    after_each(function()
        shell("rm -rf " .. quote(dir))
    end)

    -- Writes a checksum file for every file the script needs. Each entry is
    -- { sum = ..., urls = { ... } }; by default the real checksum, served from
    -- files/ (where nothing is unless a test puts it there).
    local function writeLock(entries)
        local lines = {}
        local real = {}
        for line in (readAll(LOCK) .. "\n"):gmatch("([^\n]*)\n") do
            local name, sum = line:match("^([%w][%w._-]*)%s+(%x+)")
            if name then real[name] = sum end
        end
        for _, name in ipairs(lockedNames()) do
            local entry = (entries or {})[name] or {}
            local urls = entry.urls or { "file://" .. files .. "/" .. name }
            lines[#lines + 1] = name .. " " .. (entry.sum or real[name]) .. " " .. table.concat(urls, " ")
        end
        write(dir .. "/test.lock", table.concat(lines, "\n") .. "\n")
        return dir .. "/test.lock"
    end

    local function run(lock, env)
        local started = os.time()
        local ok = shell((env or "") .. " DEV_SETUP_TEST=1 DEV_SETUP_LOCK=" .. quote(lock or writeLock()) .. " bash " .. quote(SCRIPT)
            .. " " .. quote(tools) .. " > " .. quote(dir .. "/out.txt") .. " 2>&1")
        return ok, readAll(dir .. "/out.txt") or "", os.time() - started
    end

    -- What a finished install leaves: the pinned tools and the stamp naming
    -- the script and checksum file it was installed from.
    local function fakeInstall(lock, stamp)
        local bin = tools .. "/lua51/bin"
        assert(shell("mkdir -p " .. quote(bin)))
        write(bin .. "/busted", "#!/bin/sh\necho 2.2.0\n")
        write(bin .. "/luacheck", "#!/bin/sh\nprintf 'Luacheck: 1.2.0\\nLua: Lua 5.1\\n'\n")
        assert(shell("chmod +x " .. quote(bin .. "/busted") .. " " .. quote(bin .. "/luacheck")))
        local p = io.popen("cat " .. quote(SCRIPT) .. " " .. quote(lock)
            .. " | (sha256sum 2>/dev/null || shasum -a 256) | cut -d' ' -f1")
        local want = p:read("*l")
        p:close()
        write(tools .. "/lua51/.dev-setup-stamp", (stamp or want) .. "\n")
    end

    -- Stand-ins for every download, each with its checksum: a hererocks that
    -- "installs" a luarocks which records what it builds, and lists it back.
    -- FAKE_LUAROCKS_FAIL names a rock to fail on, FAKE_LUAROCKS_SKIP one to
    -- build without installing, and FAKE_BUSTED_VERSION what busted reports.
    local FAKE_HEREROCKS = [[
import os, stat, sys
bin = os.path.join(sys.argv[1], "bin")
os.makedirs(bin)
def tool(name, text):
    path = os.path.join(bin, name)
    with open(path, "w") as f:
        f.write("#!/bin/sh\n" + text)
    os.chmod(path, stat.S_IRWXU)
tool("busted", "echo ${FAKE_BUSTED_VERSION:-2.2.0}\n")
tool("luacheck", "printf 'Luacheck: 1.2.0\\nLua: Lua 5.1\\n'\n")
tool("luarocks", """log="$(dirname "$0")/../built.txt"
if [ "$1" = list ]; then
    while read -r rock; do
        rest="${rock%-*}"
        printf '%s\\t%s\\tinstalled\\t/tree\\n' "${rest%-*}" "${rest##*-}-${rock##*-}"
    done < "$log"
    exit 0
fi
for arg; do
    case "$arg" in *.src.rock|*.rockspec) rock="$(basename "${arg%.src.rock}")"; rock="${rock%.rockspec}" ;; esac
done
[ "$rock" = "$FAKE_LUAROCKS_FAIL" ] && exit 1
[ "$rock" = "$FAKE_LUAROCKS_SKIP" ] || echo "$rock" >> "$log"
""")
]]

    local function fakeDownloads()
        local entries = {}
        for _, name in ipairs(lockedNames()) do
            local path = files .. "/" .. name
            if name:match("%.whl$") then
                write(files .. "/hererocks.py", FAKE_HEREROCKS)
                assert(shell("cd " .. quote(files) .. " && python3 -I -c 'import zipfile, sys; "
                    .. "zipfile.ZipFile(sys.argv[1], \"w\").write(\"hererocks.py\")' " .. quote(name)))
            elseif name:match("%.tar%.gz$") then
                assert(shell("mkdir -p " .. quote(files .. "/src/" .. name .. "-dir") .. " && tar -czf " .. quote(path)
                    .. " -C " .. quote(files .. "/src") .. " " .. quote(name .. "-dir")))
            else
                write(path, "stand-in for " .. name .. "\n")
            end
            entries[name] = { sum = sha256(path) }
        end
        return writeLock(entries)
    end

    local function built()
        local list = {}
        for rock in (readAll(tools .. "/lua51/built.txt") or ""):gmatch("[^\n]+") do list[#list + 1] = rock end
        return list
    end

    describe("from scratch", function()
        it("installs every pinned rock in order, marks the install good, and a second run downloads nothing", function()
            local lock = fakeDownloads()
            local ok, output = run(lock)
            assert.is_true(ok, output)
            assert.is_truthy(output:find("installed Lua 5.1.5, LuaRocks 3.8.0, busted 2.2.0-1 and luacheck 1.2.0-1", 1, true), output)
            assert.are.same({ "luafilesystem-1.9.0-1", "argparse-0.7.2-1", "luacheck-1.2.0-1", "lua_cliargs-3.0-2",
                "luasystem-0.7.1-1", "dkjson-2.11-1", "say-1.4.1-3", "luassert-1.9.0-1", "lua-term-0.8-1",
                "penlight-1.15.0-1", "mediator_lua-1.1.2-0", "busted-2.2.0-1" }, built())
            assert.is_true(exists(tools .. "/lua51/.dev-setup-stamp"))
            assert.is_false(shell("ls -d " .. quote(tools) .. "/build.* >/dev/null 2>&1"), "build folder left behind")
            assert.is_false(shell("ls " .. quote(tools) .. "/downloads/*.part* >/dev/null 2>&1"), "partial download left behind")

            -- The downloads are gone from their hosts: a second run needs none.
            assert(shell("rm -rf " .. quote(files)))
            ok, output = run(lock)
            assert.is_true(ok, output)
            assert.is_truthy(output:find("already installed", 1, true), output)
            assert.is_falsy(output:find("downloading", 1, true), output)
        end)

        it("removes the install when a build step fails, so the next run starts again", function()
            local lock = fakeDownloads()
            local ok, output = run(lock, "FAKE_LUAROCKS_FAIL=busted-2.2.0-1")
            assert.is_false(ok)
            assert.is_truthy(output:find("install failed and was removed", 1, true), output)
            assert.is_false(exists(tools .. "/lua51"))
            ok, output = run(lock)
            assert.is_true(ok, output)
            assert.is_falsy(output:find("already installed", 1, true), output)
        end)

        it("refuses an install whose busted isn't the pinned version", function()
            local ok, output = run(fakeDownloads(), "FAKE_BUSTED_VERSION=2.1.0")
            assert.is_false(ok)
            assert.is_truthy(output:find("isn't the pinned version", 1, true), output)
            assert.is_false(exists(tools .. "/lua51"))
        end)

        it("refuses an install missing a pinned rock", function()
            local ok, output = run(fakeDownloads(), "FAKE_LUAROCKS_SKIP=dkjson-2.11-1")
            assert.is_false(ok)
            assert.is_truthy(output:find("aren't the pinned ones", 1, true), output)
            assert.is_false(exists(tools .. "/lua51"))
        end)
    end)

    describe("with the pinned toolchain installed", function()
        it("does no downloads on a second run and finishes in a few seconds", function()
            -- Every URL points at a missing file, so any download would fail.
            local lock = writeLock()
            fakeInstall(lock)
            local ok, output, seconds = run(lock)
            assert.is_true(ok, output)
            assert.is_truthy(output:find("already installed", 1, true), output)
            assert.is_falsy(output:find("downloading", 1, true), output)
            assert.is_false(exists(tools .. "/downloads"))
            assert.is_true(seconds <= 5, "took " .. seconds .. "s")
        end)

        it("installs again from scratch when a pin or checksum changes", function()
            local lock = writeLock()
            fakeInstall(lock, string.rep("0", 64))
            local ok, output = run(lock)
            assert.is_false(ok)
            assert.is_falsy(output:find("already installed", 1, true), output)
            assert.is_truthy(output:find("downloading hererocks", 1, true), output)
        end)

        it("doesn't trust an install whose tools are missing or the wrong version", function()
            local lock = writeLock()
            fakeInstall(lock)
            write(tools .. "/lua51/bin/busted", "#!/bin/sh\necho 2.1.0\n")
            local ok, output = run(lock)
            assert.is_false(ok)
            assert.is_falsy(output:find("already installed", 1, true), output)

            fakeInstall(lock)
            os.remove(tools .. "/lua51/bin/luacheck")
            ok, output = run(lock)
            assert.is_false(ok)
            assert.is_falsy(output:find("already installed", 1, true), output)
        end)
    end)

    describe("with a bad download", function()
        it("stops at a checksum mismatch, names the file and installs nothing", function()
            local name = "hererocks-0.25.1-py3-none-any.whl"
            write(files .. "/" .. name, "not the file that was reviewed\n")
            local lock = writeLock()
            local ok, output = run(lock)
            assert.is_false(ok)
            assert.is_truthy(output:find("checksum mismatch for " .. name, 1, true), output)
            assert.is_false(exists(tools .. "/downloads/" .. name))
            assert.is_false(exists(tools .. "/downloads/" .. name .. ".part"))
            assert.is_false(exists(tools .. "/lua51"))

            -- And the next run doesn't take it for an install.
            ok, output = run(lock)
            assert.is_false(ok)
            assert.is_truthy(output:find("checksum mismatch for " .. name, 1, true), output)
        end)

        it("leaves an older install untrusted when a new download doesn't match", function()
            local name = "lua-5.1.5.tar.gz"
            write(files .. "/" .. name, "tampered\n")
            write(files .. "/wheel", "wheel\n")
            local lock = writeLock({ ["hererocks-0.25.1-py3-none-any.whl"] = {
                sum = sha256(files .. "/wheel"), urls = { "file://" .. files .. "/wheel" } } })
            fakeInstall(lock, string.rep("1", 64))
            local ok, output = run(lock)
            assert.is_false(ok)
            assert.is_truthy(output:find("checksum mismatch for " .. name, 1, true), output)
            ok, output = run(lock)
            assert.is_false(ok)
            assert.is_falsy(output:find("already installed", 1, true), output)
        end)

        it("names the unreachable host and the allowlist doc", function()
            local lock = writeLock({ ["hererocks-0.25.1-py3-none-any.whl"] = {
                urls = { "https://dev-setup-test.invalid/hererocks.whl" } } })
            local ok, output = run(lock)
            assert.is_false(ok)
            assert.is_truthy(output:find("couldn't download hererocks-0.25.1-py3-none-any.whl", 1, true), output)
            assert.is_truthy(output:find("dev-setup-test.invalid:", 1, true), output)
            assert.is_truthy(output:find("CONTRIBUTING.md#local-setup", 1, true), output)
            assert.is_false(exists(tools .. "/lua51"))
        end)

        it("downloads a damaged cached file again, and falls back to the next host", function()
            local name = "hererocks-0.25.1-py3-none-any.whl"
            write(files .. "/good", "the reviewed file\n")
            local lock = writeLock({ [name] = { sum = sha256(files .. "/good"),
                urls = { "https://dev-setup-test.invalid/x", "file://" .. files .. "/good" } } })
            assert(shell("mkdir -p " .. quote(tools .. "/downloads")))
            write(tools .. "/downloads/" .. name, "damaged\n")
            local ok, output = run(lock)
            assert.is_false(ok) -- the next file isn't there
            assert.is_truthy(output:find("cached " .. name .. " doesn't match its checksum", 1, true), output)
            assert.are.equal("the reviewed file\n", readAll(tools .. "/downloads/" .. name))
        end)
    end)

    it("refuses a tools folder with a space in its path, which LuaRocks can't build in", function()
        local ok, output = shell("DEV_SETUP_TEST=1 bash " .. quote(SCRIPT) .. " " .. quote(dir .. "/my tools")
            .. " > " .. quote(dir .. "/out.txt") .. " 2>&1"), readAll(dir .. "/out.txt")
        assert.is_false(ok)
        assert.is_truthy(output:find("path with spaces", 1, true), output)
        assert.is_false(exists(dir .. "/my tools"))
    end)

    it("downloads over https only, redirects included", function()
        local script = readAll(SCRIPT)
        assert.is_truthy(script:find('\nPROTOCOLS="=https"\n', 1, true))
        assert.is_truthy(script:find('curl -fsS -L --proto "$PROTOCOLS" --proto-redir =https --tlsv1.2', 1, true))
    end)

    describe("checksum file", function()
        it("refuses URLs that aren't https, malformed checksums and repeated files", function()
            local cases = {
                { ["lua-5.1.5.tar.gz"] = { urls = { "http://www.lua.org/ftp/lua-5.1.5.tar.gz" } } },
                { ["lua-5.1.5.tar.gz"] = { sum = "abc123" } },
            }
            for _, entries in ipairs(cases) do
                local ok, output = run(writeLock(entries))
                assert.is_false(ok)
                assert.is_falsy(output:find("downloading", 1, true), output)
            end
            local lock = writeLock()
            write(lock, readAll(lock) .. readAll(lock):match("^[^\n]*\n"))
            local ok, output = run(lock)
            assert.is_false(ok)
            assert.is_truthy(output:find("listed twice", 1, true), output)
        end)

        it("lists every file the script installs, each with an https URL", function()
            -- The real file, without test mode: only https is allowed.
            local names = {}
            for line in (readAll(LOCK) .. "\n"):gmatch("([^\n]*)\n") do
                local name, sum, urls = line:match("^([%w][%w._-]*)%s+(%S+)%s+(.+)$")
                if name then
                    names[name] = true
                    assert.is_truthy(sum:match("^%x+$") and #sum == 64, name)
                    for url in urls:gmatch("%S+") do
                        assert.is_truthy(url:match("^https://"), url)
                    end
                end
            end
            local script = readAll(SCRIPT)
            for _, name in ipairs({ "hererocks-0.25.1-py3-none-any.whl", "lua-5.1.5.tar.gz",
                "luarocks-3.8.0.tar.gz", "busted-2.2.0-1.src.rock", "luacheck-1.2.0-1.src.rock" }) do
                assert.is_true(names[name], name .. " missing from the checksum file")
            end
            for rock in script:match("ROCKS=%((.-)%)"):gmatch("[%w_%-%.\"$]+") do
                rock = rock:gsub('"', ""):gsub("%$LUACHECK_VERSION", "1.2.0-1"):gsub("%$BUSTED_VERSION", "2.2.0-1")
                local source = script:match(rock:gsub("%p", "%%%0") .. '%) echo "([^"]+)"')
                if source then
                    assert.is_true(names[rock .. ".rockspec"], rock .. ".rockspec missing")
                    assert.is_true(names[source], source .. " missing")
                else
                    assert.is_true(names[rock .. ".src.rock"], rock .. ".src.rock missing")
                end
            end
        end)
    end)
end)
