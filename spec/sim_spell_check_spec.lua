-- Spec: #160
-- scripts/sim-spell-check.py ties the spell data the UI simulator workflow
-- downloads to our committed copy, scripts/data/forever-spells.json, whose
-- hash the simulator's own spec records (#209). The workflow pins the
-- download's hash itself, so this check is what says the pinned file agrees
-- with the recorded one: every committed spell must have exactly the same
-- rows in the download. It runs here against changed copies of the committed
-- file, as the workflow runs it: python3 -I, two paths, exit 0 or 1.
local wow = require("spec.support.wow")

local ROOT = wow.ROOT
local CHECK = ROOT .. "/scripts/sim-spell-check.py"
local COMMITTED = ROOT .. "/scripts/data/forever-spells.json"

-- Writes a changed copy of the committed file. The change is Python run on
-- the parsed file `d`; `rows(name)` is a table's rows and `add(spell)` gives
-- every table a copy of its first row for a new spell, in order.
local EDIT = [=[
import copy, json, sys
d = json.load(open(sys.argv[1]))
COLUMN = {"Spell": "ID", "SpellEffect": "SpellID", "SpellMisc": "SpellID", "SpellName": "ID", "SpellPower": "SpellID"}
def rows(name):
    return d["tables"][name]["rows"]
def add(spell, tables=COLUMN):
    for name in tables:
        row = copy.deepcopy(rows(name)[0])
        row[COLUMN[name]] = spell
        rows(name).append(row)
        rows(name).sort(key=lambda r: r[COLUMN[name]])
exec(sys.argv[3])
json.dump(d, open(sys.argv[2], "w"), separators=(",", ":"))
]=]

describe("the UI simulator's spell data check (scripts/sim-spell-check.py, #160)", function()
    local dir

    setup(function()
        local p = io.popen("mktemp -d")
        dir = p:read("*l")
        p:close()
        local f = assert(io.open(dir .. "/edit.py", "w"))
        f:write(EDIT)
        f:close()
    end)

    teardown(function()
        os.execute("rm -rf '" .. dir .. "'")
    end)

    local made = 0
    -- A copy of the committed file after `change` (Python), as a path.
    local function copyWith(change)
        made = made + 1
        local out = dir .. "/spells-" .. made .. ".json"
        local status = os.execute(("python3 -I '%s/edit.py' '%s' '%s' '%s'"):format(dir, COMMITTED, out, change))
        assert.is_true(status == 0 or status == true, "the fixture couldn't be made: " .. change)
        return out
    end

    -- Runs the check; returns its exit status and what it printed.
    local function check(downloaded, committed, extra)
        local p = io.popen(("python3 -I '%s' %s %s %s 2>&1; echo \"EXIT:$?\""):format(CHECK,
            downloaded and ("'" .. downloaded .. "'") or "", committed and ("'" .. committed .. "'") or "", extra or ""))
        local text = p:read("*a")
        p:close()
        return tonumber(text:match("EXIT:(%d+)%s*$")), text
    end

    it("passes when the download is the committed file (white)", function()
        local code, text = check(COMMITTED, COMMITTED)
        assert.are.equal(0, code, text)
        assert.is_truthy(text:find("all 72 committed spells have the same rows", 1, true), text)
        assert.is_falsy(text:find("only the download has", 1, true), text)
    end)

    it("passes when the download adds spells, and lists them as covered by the pinned hash alone (white)", function()
        -- What the simulator's selection did on 2026-11-12: two more spells.
        local code, text = check(copyWith("add(24705); add(30754)"), COMMITTED)
        assert.are.equal(0, code, text)
        assert.is_truthy(text:find("all 72 committed spells have the same rows", 1, true), text)
        assert.is_truthy(text:find("spells only the download has (2), covered by the pinned hash alone: 24705, 30754", 1, true), text)
    end)

    it("passes when an added spell has no power row, as a spell with no cost has none (white)", function()
        local code, text = check(copyWith('add(24705, ["Spell", "SpellEffect", "SpellMisc", "SpellName"])'), COMMITTED)
        assert.are.equal(0, code, text)
    end)

    it("fails when any row of a committed spell differs, in any table (black)", function()
        local changes = {
            SpellName = 'rows("SpellName")[3]["Name_lang"] = "Another Name"',
            Spell = 'rows("Spell")[0]["Description_lang"] += " "',
            SpellMisc = 'rows("SpellMisc")[5]["SpellIconFileDataID"] += 1',
            SpellEffect = 'rows("SpellEffect")[7]["ImplicitTarget_0"] = 99',
            SpellPower = 'rows("SpellPower")[2]["ManaCost"] = 0',
        }
        for name, change in pairs(changes) do
            local code, text = check(copyWith(change), COMMITTED)
            assert.are.equal(1, code, name .. ": " .. text)
            assert.is_truthy(text:find("spell data check failed: the " .. name .. " rows of the committed spells differ", 1, true), text)
        end
    end)

    it("fails when a committed spell's row is missing, added, doubled or out of order (black)", function()
        for _, change in ipairs({
            'rows("SpellMisc").pop(4)',
            'rows("SpellPower").pop()',
            'rows("SpellEffect").insert(1, dict(rows("SpellEffect")[0]))',
            'rows("SpellName")[0], rows("SpellName")[1] = rows("SpellName")[1], rows("SpellName")[0]',
            -- A new column on one row, and one taken away.
            'rows("Spell")[9]["Extra"] = 1',
            'del rows("SpellName")[9]["Name_lang"]',
        }) do
            local code, text = check(copyWith(change), COMMITTED)
            assert.are.equal(1, code, change .. ": " .. text)
            assert.is_truthy(text:find("rows of the committed spells differ", 1, true), change .. ": " .. text)
        end
    end)

    it("tells 1 from 1.0 and from true: rows are compared as written (black)", function()
        for _, change in ipairs({ 'rows("SpellMisc")[0]["DifficultyID"] = 0.0', 'rows("SpellMisc")[0]["DifficultyID"] = False' }) do
            local code, text = check(copyWith(change), COMMITTED)
            assert.are.equal(1, code, change .. ": " .. text)
        end
    end)

    it("fails when the download lacks a committed spell, and names it by number (black)", function()
        local code, text = check(copyWith('rows("SpellName")[:] = [r for r in rows("SpellName") if r["ID"] != 131]'), COMMITTED)
        assert.are.equal(1, code, text)
        assert.is_truthy(text:find("the download lacks committed spells: 131", 1, true), text)
    end)

    it("fails when the build, the schema or a table's layout or unreadable count differs (black)", function()
        local cases = {
            ['d["build"] = "1.60.1.70707"'] = "differ in their build",
            ['d["schema"] = 2'] = "differ in their schema",
            ['d["tables"]["SpellName"]["layout_hash"] = "00000000"'] = "the SpellName tables differ in their layout_hash",
            ['d["tables"]["Spell"]["unreadable_records"] += 1'] = "the Spell tables differ in their unreadable_records",
        }
        for change, message in pairs(cases) do
            local code, text = check(copyWith(change), COMMITTED)
            assert.are.equal(1, code, change .. ": " .. text)
            assert.is_truthy(text:find(message, 1, true), change .. ": " .. text)
        end
    end)

    it("fails when a table is missing or extra, or a row names no spell or one the names table lacks (black)", function()
        local cases = {
            ['del d["tables"]["SpellPower"]'] = "doesn't hold exactly the five spell tables",
            ['d["tables"]["Other"] = {"rows": []}'] = "doesn't hold exactly the five spell tables",
            ['d["tables"]["Spell"]["rows"] = "none"'] = "Spell table has no rows",
            ['rows("SpellMisc")[0]["SpellID"] = "131"'] = "names no spell",
            ['rows("SpellMisc")[0]["SpellID"] = True'] = "names no spell",
            ['rows("SpellEffect").append(dict(rows("SpellEffect")[0], SpellID=999999))'] = "which its SpellName table lacks",
        }
        for change, message in pairs(cases) do
            local code, text = check(copyWith(change), COMMITTED)
            assert.are.equal(1, code, change .. ": " .. text)
            assert.is_truthy(text:find(message, 1, true), change .. ": " .. text)
        end
    end)

    it("fails on a file that's missing, empty, not JSON or not a table of tables, and never prints its text (black)", function()
        local function file(name, content)
            local f = assert(io.open(dir .. "/" .. name, "wb"))
            f:write(content)
            f:close()
            return dir .. "/" .. name
        end
        local hostile = "::error::from the file"
        for _, path in ipairs({ dir .. "/missing.json", file("empty.json", ""), file("text.json", hostile),
            file("list.json", "[1]"), file("string.json", '"' .. hostile .. '"'), file("notables.json", '{"tables":3}'),
            file("bad-utf8.json", "\255\254") }) do
            for _, order in ipairs({ { path, COMMITTED }, { COMMITTED, path } }) do
                local code, text = check(order[1], order[2])
                assert.are.equal(1, code, path .. ": " .. text)
                assert.is_truthy(text:find("^spell data check failed: "), text)
                assert.is_falsy(text:find("::", 1, true), "the file's text reached the output: " .. text)
            end
        end
    end)

    it("prints only numbers and table names when it fails on hostile text (black)", function()
        local code, text = check(copyWith([=[rows("SpellName")[0]["Name_lang"] = "\n::error::x"]=]), COMMITTED)
        assert.are.equal(1, code, text)
        assert.is_falsy(text:find("::", 1, true), text)
    end)

    it("needs exactly two files (black)", function()
        for _, args in ipairs({ {}, { COMMITTED }, { COMMITTED, COMMITTED, "extra" } }) do
            local code, text = check(args[1], args[2], args[3])
            assert.are.equal(1, code, text)
            assert.is_truthy(text:find("^usage: "), text)
        end
    end)
end)
