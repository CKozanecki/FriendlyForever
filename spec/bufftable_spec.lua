-- Spec: #209
-- The buff table (BuffTable.lua) is generated from Forever's own spell data
-- by scripts/gen_spell_table.py, once per game version. The addon never looks
-- IDs up while you play. This spec checks the committed table is valid, that
-- the generator reproduces it exactly from the committed source file, that the
-- generator refuses damaged data and writes nothing, and that saved settings
-- naming a buff that is not in the table still load. CI does not download from
-- Blizzard: the extraction itself is run by hand (CONTRIBUTING.md, Releasing).
local wow = require("spec.support.wow")

local ROOT = wow.ROOT
local MAX_SPELL_ID = 1000000
local SOURCE = ROOT .. "/scripts/data/forever-spells.json"
local BUFFS = ROOT .. "/scripts/spell-buffs.json"
local GENERATOR = ROOT .. "/scripts/gen_spell_table.py"
-- The SHA-256 upstream's docs/specs/forever-spell-data.md records for the
-- Forever build 1.60.1.70685 (Osso/wow-ui-sim).
local UPSTREAM_SHA = "13122873d813481e85815946ddf964068b04132d4d2b2b44ba5ce61491595ad0"

local function read(path)
    local f = assert(io.open(path, "rb"))
    local text = f:read("*a")
    f:close()
    return text
end

local function write(path, text)
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
end

local function sha256(path)
    -- sha256sum, or shasum on a host that has only that (macOS), as dev-setup.sh does.
    local p = io.popen('(sha256sum "' .. path .. '" 2>/dev/null || shasum -a 256 "' .. path .. '")')
    local out = p:read("*a")
    p:close()
    return out:match("^(%x+)")
end

local function tmpdir()
    local p = io.popen("mktemp -d")
    local dir = p:read("*l")
    p:close()
    return dir
end

-- Runs the generator; returns its exit status and combined output.
local function generate(spells, buffs, out, extra)
    local cmd = ('python3 -I "%s" --spells "%s" --buffs "%s" --out "%s" %s 2>&1; echo "EXIT:$?"')
        :format(GENERATOR, spells, buffs, out, extra or "")
    local p = io.popen(cmd)
    local text = p:read("*a")
    p:close()
    local code = tonumber(text:match("EXIT:(%d+)%s*$"))
    return code, text
end

-- The problems with a table, as a list of strings (empty when it is valid).
local function problems(t)
    local out = {}
    local function bad(msg) out[#out + 1] = msg end
    local function validId(id) return type(id) == "number" and id == math.floor(id) and id >= 1 and id <= MAX_SPELL_ID end
    if t.format ~= 1 then bad("format") end
    if type(t.build) ~= "string" or not t.build:match("^%d+%.%d+%.%d+%.%d+$") then bad("build") end
    if type(t.sourceSha256) ~= "string" or not t.sourceSha256:match("^%x+$") or #t.sourceSha256 ~= 64 then
        bad("sourceSha256")
    end
    local rankOwner, keys = {}, {}
    for class, list in pairs(t.classes) do
        for _, buff in ipairs(list) do
            if type(buff.key) ~= "string" or buff.key == "" then bad(class .. ": a buff has no key") end
            if keys[buff.key] then bad("key twice: " .. tostring(buff.key)) end
            keys[buff.key] = true
            if type(buff.name) ~= "string" or buff.name == "" or #buff.name > 100 then
                bad(tostring(buff.key) .. ": no name")
            end
            if type(buff.ranks) ~= "table" or #buff.ranks == 0 then bad(tostring(buff.key) .. ": no ranks") end
            for _, field in ipairs({ "ranks", "group", "blockers" }) do
                local seen = {}
                for _, id in ipairs(buff[field] or {}) do
                    if not validId(id) then bad(tostring(buff.key) .. " " .. field .. ": bad ID " .. tostring(id)) end
                    if seen[id] then bad(tostring(buff.key) .. " " .. field .. ": " .. tostring(id) .. " twice") end
                    seen[id] = true
                    if field == "ranks" then
                        if rankOwner[id] then bad("rank " .. tostring(id) .. " of two buffs") end
                        rankOwner[id] = buff.key
                    end
                end
            end
        end
    end
    for _, key in ipairs(t.absent) do
        if keys[key] then bad("absent but present: " .. key) end
    end
    for _, id in ipairs(t.removedSpells) do
        if not validId(id) then bad("removed spell " .. tostring(id)) end
        if rankOwner[id] then bad("removed but a rank: " .. tostring(id)) end
    end
    return out
end

local function deepCopy(v)
    if type(v) ~= "table" then return v end
    local c = {}
    for k, x in pairs(v) do c[k] = deepCopy(x) end
    return c
end

describe("The generated buff table", function()
    local ns
    before_each(function() ns = wow.boot() end)

    describe("the committed table (white)", function()
        it("is valid: whole IDs in range, no rank shared by two buffs, every buff named", function()
            assert.are.same({}, problems(ns.BuffTable))
        end)

        it("records the game build and the source file's hash, and the source is upstream's checked file", function()
            assert.are.equal("1.60.1.70685", ns.BuffTable.build)
            assert.are.equal(UPSTREAM_SHA, ns.BuffTable.sourceSha256)
            assert.are.equal(UPSTREAM_SHA, sha256(SOURCE))
        end)

        it("is reproduced exactly when the generator runs on the committed source", function()
            local dir = tmpdir()
            local code, text = generate(SOURCE, BUFFS, dir .. "/BuffTable.lua")
            assert.are.equal(0, code, text)
            assert.is_true(read(dir .. "/BuffTable.lua") == read(ROOT .. "/BuffTable.lua"),
                "BuffTable.lua differs from what the generator makes: re-run it (CONTRIBUTING.md, Releasing)")
            os.execute('rm -rf "' .. dir .. '"')
        end)

        it("gives a report that lists every buff and spell found or not found", function()
            local dir = tmpdir()
            local code, text = generate(SOURCE, BUFFS, dir .. "/BuffTable.lua")
            assert.are.equal(0, code, text)
            for _, class in pairs(ns.BuffTable.classes) do
                for _, buff in ipairs(class) do
                    assert.is_truthy(text:find("FOUND  %u+ " .. buff.key .. ":"), buff.key)
                end
            end
            assert.is_truthy(text:find("REMOVED  light:", 1, true))
            assert.is_truthy(text:find("REMOVED  salvation:", 1, true))
            os.execute('rm -rf "' .. dir .. '"')
        end)

        it("works with IDs that differ from Classic's: every buff is recognised, offered and cast by name", function()
            -- A copy of the table with every ID moved, so none is Classic's.
            local made = deepCopy(ns.BuffTable)
            local offset = 700000
            for _, list in pairs(made.classes) do
                for _, buff in ipairs(list) do
                    for _, field in ipairs({ "ranks", "group", "blockers" }) do
                        for i, id in ipairs(buff[field] or {}) do buff[field][i] = id + offset end
                    end
                    for _, id in ipairs(buff.ranks) do wow.SPELL_NAMES[id] = buff.name end
                end
            end
            local function walk(class)
                local known = {}
                for _, id in ipairs(made.classes[class][1].ranks) do known[id] = true end
                ns = wow.boot({ buffTable = made, before = function(state)
                    state.class = class
                    state.knownSpells = known
                end })
                -- The whole table: every ID of every buff belongs to it.
                for _, list in pairs(made.classes) do
                    for _, buff in ipairs(list) do
                        assert.are.equal(buff, ns.BuffData.ByKey(buff.key))
                        for _, field in ipairs({ "ranks", "group", "blockers" }) do
                            for _, id in ipairs(buff[field] or {}) do
                                assert.is_true(ns.BuffData.Covers(buff, id), buff.key .. " " .. id)
                            end
                        end
                        for _, id in ipairs(buff.ranks) do
                            assert.are.equal(buff, ns.BuffData.ForCast(id), buff.key)
                            assert.are.equal(buff.name, ns.BuffData.SpellName(buff))
                        end
                        assert.is_nil(ns.BuffData.ForAura(buff.ranks[1] - offset), "Classic's ID means nothing")
                    end
                end
            end
            for class in pairs(made.classes) do walk(class) end
            -- A pressed cast, by name.
            walk("DRUID")
            local offered = ns.BuffData.Offerable()
            assert.are.equal("motw", offered[1].key)
            ns.BuffButton.Frame()
            wow.setGroup("party", { "Ann-Vale" })
            wow.state.units.party1.class = "WARRIOR"
            _G.SlashCmdList.FRIENDLYFOREVER("buffmode on")
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.advance(0)
            ns.BuffButton.Refresh()
            wow.pressKey("MOUSEWHEELUP")
            local cast = wow.casts[1]
            assert.is_truthy(cast, "a cast happened")
            assert.are.equal("Mark of the Wild", cast.spell)
            for id in pairs(wow.SPELL_NAMES) do if id > offset then wow.SPELL_NAMES[id] = nil end end
        end)
    end)

    describe("a new file after an update (black)", function()
        it("asks for a restart when only BuffTable.lua is new, and nothing errors", function()
            wow.reset()
            local loaded = {}
            local _, files = wow.parseToc()
            for _, file in ipairs(files) do
                if file ~= "BuffTable.lua" then assert(loadfile(wow.ROOT .. file))(wow.ADDON_NAME, loaded) end
            end
            wow.fire("ADDON_LOADED", wow.ADDON_NAME)
            wow.fire("PLAYER_ENTERING_WORLD", true, false)
            assert.are.same({}, wow.errors)
            assert.is_truthy(table.concat(wow.printed, "\n"):find("Restart the game", 1, true))
        end)
    end)

    describe("the checker (black)", function()
        it("catches a hand-damaged table", function()
            local function damaged(edit)
                local t = deepCopy(ns.BuffTable)
                edit(t)
                return problems(t)
            end
            assert.are_not.same({}, damaged(function(t) t.classes.DRUID[1].ranks[1] = 1.5 end), "fractional")
            assert.are_not.same({}, damaged(function(t) t.classes.DRUID[1].ranks[1] = -3 end), "negative")
            assert.are_not.same({}, damaged(function(t) t.classes.DRUID[1].ranks[1] = 2 ^ 40 end), "huge")
            assert.are_not.same({}, damaged(function(t) t.classes.DRUID[1].ranks[1] = "9885" end), "not a number")
            assert.are_not.same({}, damaged(function(t) t.classes.DRUID[1].ranks[2] = t.classes.DRUID[1].ranks[1] end),
                "duplicate in a list")
            assert.are_not.same({}, damaged(function(t) t.classes.DRUID[2].ranks[1] = t.classes.DRUID[1].ranks[1] end),
                "a rank of two buffs")
            assert.are_not.same({}, damaged(function(t) t.classes.DRUID[1].name = nil end), "no name")
            assert.are_not.same({}, damaged(function(t) t.sourceSha256 = "abc" end), "bad hash")
        end)
    end)

    describe("the generator refuses damaged data and writes nothing (black)", function()
        local dir
        local BUFF_JSON = '{"format":1,"classes":{"DRUID":[{"key":"thorns","name":"Thorns"}]},"removed":[]}'

        local function spells(id, name, rank, extra)
            return ('{"schema":1,"build":"1.60.1.70685","tables":{"Spell":{"rows":[{"ID":%s,"NameSubtext_lang":%s}%s]},'
                .. '"SpellName":{"rows":[{"ID":%s,"Name_lang":%s}%s]}}}')
                :format(id, rank, extra and extra[1] or "", id, name, extra and extra[2] or "")
        end

        before_each(function()
            dir = tmpdir()
            write(dir .. "/buffs.json", BUFF_JSON)
        end)
        after_each(function() os.execute('rm -rf "' .. dir .. '"') end)

        local function refuses(json, why)
            write(dir .. "/spells.json", json)
            write(dir .. "/out.lua", "KEEP")
            local code, text = generate(dir .. "/spells.json", dir .. "/buffs.json", dir .. "/out.lua")
            assert.are.equal(1, code, why .. ": " .. text)
            assert.is_truthy(text:find("nothing written", 1, true), why)
            assert.are.equal("KEEP", read(dir .. "/out.lua"), why .. ": the old file was touched")
            local p = io.popen('ls -A "' .. dir .. '"')
            local listing = p:read("*a")
            p:close()
            assert.is_falsy(listing:find(".bufftable-", 1, true), why .. ": a partial file was left")
        end

        it("works on good data", function()
            write(dir .. "/spells.json", spells(467, '"Thorns"', '"Rank 1"'))
            local code, text = generate(dir .. "/spells.json", dir .. "/buffs.json", dir .. "/out.lua")
            assert.are.equal(0, code, text)
            assert.is_truthy(read(dir .. "/out.lua"):find('ranks = { 467 }', 1, true))
        end)

        it("refuses an ID that is fractional, negative, huge, zero, a string, null or a boolean", function()
            for _, id in ipairs({ "1.5", "-4", "99999999999", "0", '"467"', "null", "true", "467.0" }) do
                refuses(spells(id, '"Thorns"', '"Rank 1"'), "ID " .. id)
            end
        end)

        it("refuses a name that is missing, not a string, empty or too long", function()
            for _, name in ipairs({ "null", "5", '""', '"' .. string.rep("x", 101) .. '"' }) do
                refuses(spells(467, name, '"Rank 1"'), "name " .. name)
            end
        end)

        it("refuses a duplicated spell, NaN, and a file that is not JSON", function()
            refuses(spells(467, '"Thorns"', '"Rank 1"', { "", ',{"ID":467,"Name_lang":"Thorns"}' }), "duplicate name row")
            refuses(spells(467, '"Thorns"', '"Rank 1"', { ',{"ID":467,"NameSubtext_lang":"Rank 2"}', "" }),
                "duplicate spell row")
            refuses(spells("NaN", '"Thorns"', '"Rank 1"'), "NaN")
            refuses("not json at all", "not JSON")
            refuses("", "empty")
        end)

        it("refuses a rank shared by two buffs", function()
            write(dir .. "/buffs.json",
                '{"format":1,"classes":{"DRUID":[{"key":"thorns","name":"Thorns"},{"key":"other","name":"Thorns"}]},"removed":[]}')
            refuses(spells(467, '"Thorns"', '"Rank 1"'), "shared rank")
        end)

        it("leaves a buff out, and says so, when the data does not have its spell", function()
            write(dir .. "/spells.json", spells(467, '"Thorns"', '"Rank 1"'))
            write(dir .. "/buffs.json",
                '{"format":1,"classes":{"DRUID":[{"key":"thorns","name":"Thorns"},{"key":"gone","name":"Nothing"}]},"removed":[]}')
            local code, text = generate(dir .. "/spells.json", dir .. "/buffs.json", dir .. "/out.lua")
            assert.are.equal(0, code, text)
            assert.is_truthy(text:find("NOT FOUND  gone", 1, true), text)
            local out = read(dir .. "/out.lua")
            assert.is_falsy(out:find('key = "gone"', 1, true))
            assert.is_truthy(out:find('absent = { "gone" }', 1, true))
        end)
    end)

    describe("a buff that is not in the table (black)", function()
        it("is not offered or listed, but saved settings that name it load and keep their values", function()
            local db = {
                buffBack = {
                    buffOrder = { "light", "kings" },
                    neverOffer = { light = true, kings = true },
                    whoGets = { light = { rule = "tanks" }, kings = { rule = "tanks" } },
                },
            }
            ns = wow.boot({ db = db, before = function(state)
                state.class = "PALADIN"
                state.knownSpells = { [20217] = true, [19977] = true }
            end })
            assert.are.same({}, wow.errors)
            local b = ns.db.buffBack
            assert.are.equal("light", b.buffOrder[1])
            assert.is_true(b.neverOffer.light)
            assert.are.equal("tanks", b.whoGets.light.rule)
            assert.is_nil(ns.BuffData.ByKey("light"))
            assert.is_true(ns.BuffData.KEYS.light)
            for _, buff in ipairs(ns.BuffData.Offerable()) do assert.are_not.equal("light", buff.key) end
            for _, buff in ipairs(ns.BuffData.ClassBuffs()) do assert.are_not.equal("light", buff.key) end
            assert.is_nil(ns.BuffData.ForAura(19977), "Light's spell is nobody's buff")
            assert.is_true(ns.BuffData.IsRemoved(19977))
        end)
    end)
end)
