-- Spec: #209, #44
-- The buff table (BuffTable.lua) is generated from Forever's own spell data
-- by scripts/gen_spell_table.py, once per game version. The addon never looks
-- IDs up while you play. This spec checks the committed table is valid, that
-- the generator reproduces it exactly from the committed source file, that the
-- generator refuses damaged data and writes nothing, and that saved settings
-- naming a buff that is not in the table still load. CI never makes this
-- file: the extraction itself is run by hand (CONTRIBUTING.md, Releasing).
local wow = require("spec.support.wow")

local ROOT = wow.ROOT
local MAX_SPELL_ID = 1000000
-- The generator's source: upstream's extraction with the self-buffs' spells
-- added to its ID list (#44; docs/forever-facts.md has how it was made).
local SOURCE = ROOT .. "/scripts/data/forever-spells-extended.json"
local SOURCE_SHA = "43d0cfa0a207b9fc0bc9ae5ea76b70b3d2ecb8779f4b33b92e288ce45d7cc45b"
-- Upstream's own, smaller extraction, the copy the UI simulator checks (#160).
local UPSTREAM = ROOT .. "/scripts/data/forever-spells.json"
local BUFFS = ROOT .. "/scripts/spell-buffs.json"
local GENERATOR = ROOT .. "/scripts/gen_spell_table.py"
local CHECK = ROOT .. "/scripts/sim-spell-check.py"
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
            local isGroup, isRank = {}, {}
            for _, id in ipairs(buff.group or {}) do isGroup[id] = true end
            for _, id in ipairs(buff.ranks or {}) do isRank[id] = true end
            if buff.groupCast and buff.groupCast.scope ~= "party" and buff.groupCast.scope ~= "class" then
                bad(tostring(buff.key) .. ": group cast scope")
            end
            for _, spell in ipairs(buff.groupCast and buff.groupCast.spells or {}) do
                if not validId(spell.id) or not isGroup[spell.id] then bad(tostring(buff.key) .. ": group cast ID") end
                if not validId(spell.reagent) then bad(tostring(buff.key) .. ": group cast reagent") end
                if not isRank[spell.equals] then bad(tostring(buff.key) .. ": group cast equals") end
            end
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

        it("records the game build and the source file's hash, the extraction recorded in docs/forever-facts.md", function()
            assert.are.equal("1.60.1.70685", ns.BuffTable.build)
            assert.are.equal("forever-spells-extended.json", ns.BuffTable.source)
            assert.are.equal(SOURCE_SHA, ns.BuffTable.sourceSha256)
            assert.are.equal(SOURCE_SHA, sha256(SOURCE))
            assert.is_truthy(read(ROOT .. "/docs/forever-facts.md"):find(SOURCE_SHA, 1, true),
                "docs/forever-facts.md doesn't record the source's SHA-256")
        end)

        it("comes from a source with every spell of upstream's checked file, row for row (#44)", function()
            assert.are.equal(UPSTREAM_SHA, sha256(UPSTREAM))
            -- sim-spell-check.py <larger> <smaller>: every spell of the smaller
            -- file has exactly the same rows, tables and build in the larger.
            local p = io.popen(('python3 -I "%s" "%s" "%s" 2>&1; echo "EXIT:$?"'):format(CHECK, SOURCE, UPSTREAM))
            local text = p:read("*a")
            p:close()
            assert.are.equal("0", text:match("EXIT:(%d+)%s*$"), text)
            assert.is_truthy(text:find("all 72 committed spells have the same rows", 1, true), text)
        end)

        it("comes from a source holding every spell ID of scripts/data/forever-spell-ids-extra.txt, and every "
            .. "spell the table names (#44)", function()
            -- The IDs added to upstream's list for the larger extraction, one
            -- per line, so the next extraction can add to them.
            local extra, count = {}, 0
            for line in read(ROOT .. "/scripts/data/forever-spell-ids-extra.txt"):gmatch("([^\n]*)\n") do
                local id = tonumber(line:match("^(%d+)$"))
                assert.is_truthy(id, "not a spell ID: '" .. line .. "'")
                assert.is_nil(extra[id], "listed twice: " .. line)
                extra[id], count = true, count + 1
            end
            assert.are.equal(71, count)
            local p = io.popen(('python3 -I -c "%s" "%s"'):format(
                "import json,sys; d=json.load(open(sys.argv[1])); "
                    .. "print(' '.join(str(r['ID']) for r in d['tables']['SpellName']['rows']))", SOURCE))
            local inSource = {}
            for id in p:read("*a"):gmatch("%d+") do inSource[tonumber(id)] = true end
            p:close()
            for id in pairs(extra) do assert.is_true(inSource[id], "listed but not extracted: " .. id) end
            for _, list in pairs(ns.BuffTable.classes) do
                for _, buff in ipairs(list) do
                    for _, field in ipairs({ "ranks", "group", "blockers" }) do
                        for _, id in ipairs(buff[field] or {}) do
                            assert.is_true(inSource[id], buff.key .. " " .. id .. " is not in the source")
                        end
                    end
                end
            end
        end)

        it("names each self-buff (#44) at the IDs the simulated client gives its spells, highest rank first", function()
            -- wow.SELF_RANKS is the simulated client's own list (Classic Era's
            -- IDs); a re-extraction that moves an ID must move it there too.
            local function ids(...)
                local out = {}
                for _, name in ipairs({ ... }) do
                    for _, id in ipairs(assert(wow.SELF_RANKS[name], name)) do out[#out + 1] = id end
                end
                return out
            end
            local expected = {
                battleshout = ids("Battle Shout"), innerfire = ids("Inner Fire"),
                icearmor = ids("Ice Armor", "Frost Armor"), magearmor = ids("Mage Armor"),
                demonarmor = ids("Demon Armor", "Demon Skin"), lightningshield = ids("Lightning Shield"),
                righteousfury = ids("Righteous Fury"), omen = ids("Omen of Clarity"),
                hawk = ids("Aspect of the Hawk"), monkey = ids("Aspect of the Monkey"),
                wildaspect = ids("Aspect of the Wild"), trueshot = ids("Trueshot Aura"),
                devotion = ids("Devotion Aura"), retribution = ids("Retribution Aura"),
                concentration = ids("Concentration Aura"), shadowaura = ids("Shadow Resistance Aura"),
                frostaura = ids("Frost Resistance Aura"), fireaura = ids("Fire Resistance Aura"),
                sanctity = ids("Sanctity Aura"),
            }
            local seen = {}
            for _, list in pairs(ns.BuffTable.classes) do
                for _, buff in ipairs(list) do
                    if buff.selfCast then
                        assert.is_truthy(expected[buff.key], "an unexpected self-buff: " .. buff.key)
                        assert.are.same(expected[buff.key], buff.ranks, buff.key)
                        seen[buff.key] = true
                    end
                end
            end
            for key in pairs(expected) do assert.is_true(seen[key], key .. " is missing from the table") end
            assert.are.same(ids("Aspect of the Cheetah", "Aspect of the Pack", "Aspect of the Beast"),
                ns.BuffTable.familyAuras.aspect)
            assert.are.same({ "light" }, ns.BuffTable.absent)
        end)

        it("keeps the buff defaults of #219/#221: Thorns tanks only, Wisdom and Might by class", function()
            local function buff(key) return ns.BuffData.ByKey(key) end
            assert.are.equal("tanks", buff("thorns").defaultRule)
            assert.are.equal("classes", buff("wisdom").defaultRule)
            assert.are.equal("classes", buff("might").defaultRule)
            assert.are.same({ PALADIN = true, HUNTER = true, PRIEST = true, SHAMAN = true, MAGE = true, WARLOCK = true,
                DRUID = true }, buff("wisdom").defaultClasses)
            assert.are.same({ WARRIOR = true, PALADIN = true, HUNTER = true, ROGUE = true, SHAMAN = true, DRUID = true },
                buff("might").defaultClasses)
            assert.is_nil(buff("kings").defaultRule)
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
                for _, buff in ipairs(made.classes[class]) do
                    for _, id in ipairs(buff.ranks) do known[id] = true end
                end
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
            for class in pairs(made.classes) do
                walk(class)
                -- Knowing every rank of every buff of the class, all of them are offered, in its order.
                local keys, want = {}, {}
                for _, buff in ipairs(ns.BuffData.Offerable()) do keys[#keys + 1] = buff.key end
                -- Self-buffs (#44) after them, in the class's order too.
                for _, buff in ipairs(ns.BuffData.SelfOfferable()) do keys[#keys + 1] = buff.key end
                -- Righteous Fury is "Never offer" until you choose (#44, owner's Q4).
                for _, buff in ipairs(made.classes[class]) do
                    if not buff.defaultNever then want[#want + 1] = buff.key end
                end
                assert.are.same(want, keys, class)
            end
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

    describe("a damaged rule for a buff that is not in the table (black)", function()
        local function bootPaladin(db)
            return wow.boot({ db = db, before = function(state)
                state.class = "PALADIN"
                state.knownSpells = { [20217] = true }
            end })
        end

        it("loads without error and keeps the other settings", function()
            ns = bootPaladin({ buffBack = { neverOffer = { kings = true },
                whoGets = { light = { rule = "classes", classes = "junk" } } } })
            assert.are.same({}, wow.errors)
            assert.is_not_nil(ns.db)
            assert.is_true(ns.db.buffBack.neverOffer.kings)
            assert.are.equal("classes", ns.db.buffBack.whoGets.light.rule)
        end)

        it("is cleaned, not raised, when pasted in a settings line", function()
            ns = bootPaladin({})
            local line = "FF1:{Ssettings;{SbuffBack;{SwhoGets;{Slight;{Sclasses;N1;Srule;Sclasses;}}}}Sv;N1;}"
            local ok = pcall(ns.Profiles.Import, line)
            assert.is_true(ok, "importing a damaged rule for a buff not in the table must not raise")
            assert.are.same({}, wow.errors)
            assert.are.equal("classes", ns.db.buffBack.whoGets.light.rule, "and its rule is kept")
        end)

        it("can have a class ticked from a saved key without error (a call with the key alone)", function()
            ns = bootPaladin({})
            ns.BuffButton.Frame()
            local ok, err = pcall(ns.BuffRules.SetClass, "light", "WARRIOR", true)
            assert.is_true(ok, tostring(err))
            assert.is_true(ns.db.buffBack.whoGets.light.classes.WARRIOR)
        end)

        it("keeps a buff's settings through a profile switch (profiles keep their values)", function()
            ns = bootPaladin({ buffBack = { neverOffer = { light = true },
                whoGets = { light = { rule = "tanks", never = { ["bo-lake"] = "Bo-Lake" } } } } })
            assert.is_truthy(ns.Profiles.New("Raiding"))
            assert.is_truthy(ns.Profiles.New("Other"))
            for _, name in ipairs({ "Raiding", "Other", "Raiding" }) do
                assert.is_truthy(ns.Profiles.Use(name))
                local b = ns.db.buffBack
                assert.are.same({}, wow.errors)
                assert.is_true(b.neverOffer.light, name)
                assert.are.equal("tanks", b.whoGets.light.rule, name)
                assert.are.equal("Bo-Lake", b.whoGets.light.never["bo-lake"], name)
            end
        end)

        it("is cleaned by the rules' own repair without error", function()
            ns = bootPaladin({})
            local ok, cleaned = pcall(ns.BuffRules.Clean, { light = { rule = "classes", classes = 5 } })
            assert.is_true(ok, tostring(cleaned))
            assert.are.equal("classes", cleaned.light.rule)
        end)
    end)

    describe("chaos (red tests)", function()
        it("damaged saved data naming Blessing of Light, group changes and Light auras never error or offer Light", function()
            local random = require("spec.support.random")
            local LIGHT_IDS = { 19977, 19978, 19979, 25890 }
            local reached = { whoGets = 0, whoGetsAll = 0, neverOffer = 0, buffOrder = 0, kept = 0, casts = 0 }
            wow.SPELL_NAMES[19977] = "Blessing of Light"
            wow.SPELL_NAMES[25890] = "Greater Blessing of Light"
            local function tokenOf(id)
                for token, u in pairs(wow.state.units) do
                    if u.id == id and token ~= "target" then return token end
                end
            end
            for _, seed in ipairs({ 11, 209, 1109, 2026 }) do
                random.seed(seed)
                local junk = { 7, true, "x", {}, { rule = {} }, "light", { "light" },
                    { rule = "classes", classes = "junk" }, { rule = "classes", classes = 5 } }
                local function pick() return junk[random.random(#junk)] end
                for load = 1, 5 do
                    local b = { buffOrder = { "light", "kings" }, neverOffer = { light = true },
                        whoGets = { light = { rule = "tanks" }, kings = { rule = "all" } } }
                    if load > 1 then
                        if random.random() < 0.6 then b.whoGets.light = pick() reached.whoGets = reached.whoGets + 1 end
                        if random.random() < 0.3 then b.whoGets = pick() reached.whoGetsAll = reached.whoGetsAll + 1 end
                        if random.random() < 0.5 then b.neverOffer = { light = pick() } reached.neverOffer = reached.neverOffer + 1 end
                        if random.random() < 0.5 then b.buffOrder = { "light", pick(), "kings" } reached.buffOrder = reached.buffOrder + 1 end
                    end
                    ns = wow.boot({ db = { buffBack = b }, before = function(state)
                        state.class = "PALADIN"
                        state.knownSpells = { [20217] = true, [19742] = true, [19740] = true,
                            [19977] = true, [19978] = true, [19979] = true, [25890] = true }
                    end })
                    assert.are.same({}, wow.errors, ("seed %d load %d"):format(seed, load))
                    if load == 1 then
                        assert.are.equal("tanks", ns.db.buffBack.whoGets.light.rule, "valid light values survive")
                        reached.kept = reached.kept + 1
                    end
                    ns.BuffButton.Frame()
                    _G.SlashCmdList.FRIENDLYFOREVER("buffmode on")
                    local names = { "Ann-Vale", "Bo-Lake", "Cid-Rock", "Dot-Fern", "Eve-Moss" }
                    local classes = { "WARRIOR", "ROGUE", "MAGE", "PRIEST", "PALADIN" }
                    local actions = {
                        function()
                            local members = {}
                            for _, name in ipairs(names) do
                                if random.random() < 0.7 then members[#members + 1] = name end
                            end
                            if #members == 0 then members[1] = names[1] end
                            wow.setGroup(random.random() < 0.5 and "raid" or "party", members)
                            local prefix = wow.state.groupType == "raid" and "raid" or "party"
                            for i = 1, #members do
                                local u = wow.state.units[prefix .. i]
                                if u then u.class = classes[random.random(#classes)] end
                            end
                            wow.fire("GROUP_ROSTER_UPDATE")
                            wow.advance(0)
                        end,
                        function()
                            for token, u in pairs(wow.state.units) do
                                if (token:find("^party%d") or token:find("^raid%d")) and random.random() < 0.4 then
                                    u.auras, u.auraSources = u.auras or {}, u.auraSources or {}
                                    u.auras[#u.auras + 1] = LIGHT_IDS[random.random(#LIGHT_IDS)]
                                    u.auraSources[#u.auras] = random.random() < 0.5 and "player" or "raid9"
                                end
                            end
                        end,
                        function()
                            ns.db.buffBack.whoGets = ns.db.buffBack.whoGets
                            ns.db.buffBack.neverOffer = random.random() < 0.5 and pick() or { light = pick() }
                            ns.BuffButton.Refresh()
                        end,
                        function() ns.Config.Repair() end,
                        function() wow.advance(random.random() * 20) end,
                    }
                    for step = 1, 60 do
                        actions[random.random(#actions)]()
                        ns.BuffButton.Refresh()
                        local before = #wow.casts
                        wow.pressKey("MOUSEWHEELUP")
                        local cast = wow.casts[before + 1]
                        if cast then
                            reached.casts = reached.casts + 1
                            local where = ("seed %d load %d step %d"):format(seed, load, step)
                            assert.is_falsy(tostring(cast.spell):find("Light", 1, true), where)
                            for _, id in ipairs(LIGHT_IDS) do assert.are_not.equal(id, cast.id, where) end
                            local u = wow.state.units[tokenOf(cast.target)]
                            if u and not cast.failed then
                                u.auras, u.auraSources = u.auras or {}, u.auraSources or {}
                                u.auras[#u.auras + 1] = cast.id
                                u.auraSources[#u.auras] = "player"
                            end
                        end
                    end
                    assert.are.same({}, wow.errors, ("seed %d load %d"):format(seed, load))
                end
            end
            wow.SPELL_NAMES[19977], wow.SPELL_NAMES[25890] = nil, nil
            for kind, n in pairs(reached) do assert.is_true(n > 0, "the storm never reached " .. kind) end
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
            assert.are_not.same({}, damaged(function(t) t.classes.DRUID[1].groupCast.spells[1].id = 1 end),
                "a group cast that is not a group version")
            assert.are_not.same({}, damaged(function(t) t.classes.DRUID[1].groupCast.scope = "raid" end),
                "a group cast scope that is neither party nor class")
            assert.are_not.same({}, damaged(function(t) t.classes.PALADIN[1].groupCast.scope = "Class" end),
                "a mistyped scope")
            assert.are_not.same({}, damaged(function(t) t.classes.DRUID[1].groupCast.spells[1].reagent = 1.5 end),
                "a fractional reagent")
            assert.are_not.same({}, damaged(function(t) t.classes.DRUID[1].groupCast.spells[1].equals = 1 end),
                "an equals that is not a rank")
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

        it("refuses a group cast whose scope is neither party nor class (it decides who a cast reaches)", function()
            write(dir .. "/buffs.json", '{"format":1,"classes":{"DRUID":[{"key":"thorns","name":"Thorns",'
                .. '"groupCast":{"scope":"SCOPE","spells":[]}}]},"removed":[]}')
            local template = read(dir .. "/buffs.json")
            for _, scope in ipairs({ "raid", "Class", "", "all" }) do
                write(dir .. "/buffs.json", (template:gsub("SCOPE", scope)))
                refuses(spells(467, '"Thorns"', '"Rank 1"'), "scope " .. scope)
            end
            write(dir .. "/buffs.json", (template:gsub("SCOPE", "class")))
            write(dir .. "/spells.json", spells(467, '"Thorns"', '"Rank 1"'))
            local code, text = generate(dir .. "/spells.json", dir .. "/buffs.json", dir .. "/out.lua")
            assert.are.equal(0, code, "class is accepted: " .. text)
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

    describe("the generator's self-buff fields (#44)", function()
        local dir
        before_each(function() dir = tmpdir() end)
        after_each(function() os.execute('rm -rf "' .. dir .. '"') end)

        -- Spell data with these { id, name, rank } rows.
        local function data(rows)
            local spell, names = {}, {}
            for _, r in ipairs(rows) do
                spell[#spell + 1] = ('{"ID":%d,"NameSubtext_lang":"Rank %d"}'):format(r[1], r[3])
                names[#names + 1] = ('{"ID":%d,"Name_lang":"%s"}'):format(r[1], r[2])
            end
            return '{"schema":1,"build":"1.60.1.70685","tables":{"Spell":{"rows":[' .. table.concat(spell, ",")
                .. ']},"SpellName":{"rows":[' .. table.concat(names, ",") .. ']}}}'
        end
        local ROWS = { { 7302, "Ice Armor", 1 }, { 7320, "Ice Armor", 2 }, { 168, "Frost Armor", 1 },
            { 7300, "Frost Armor", 2 }, { 13163, "Aspect of the Monkey", 1 }, { 5118, "Aspect of the Cheetah", 1 },
            { 25780, "Righteous Fury", 1 } }

        local function run(buffs)
            write(dir .. "/spells.json", data(ROWS))
            write(dir .. "/buffs.json", buffs)
            write(dir .. "/out.lua", "KEEP")
            local code, text = generate(dir .. "/spells.json", dir .. "/buffs.json", dir .. "/out.lua")
            return code, text, read(dir .. "/out.lua")
        end

        it("makes one buff of two spells, the main name's ranks first (white)", function()
            local code, text, out = run('{"format":1,"classes":{"MAGE":[{"key":"icearmor","name":"Ice Armor",'
                .. '"alsoNames":["Frost Armor"],"family":"armor","selfCast":true}]},"removed":[]}')
            assert.are.equal(0, code, text)
            assert.is_truthy(out:find("ranks = { 7320, 7302, 7300, 168 }", 1, true), out)
            assert.is_truthy(out:find('family = "armor"', 1, true))
            assert.is_truthy(out:find("selfCast = true", 1, true))
        end)

        it("writes toggle, defaultNever and the family's other spells (white)", function()
            local code, text, out = run('{"format":1,"classes":{"HUNTER":[{"key":"monkey","name":"Aspect of the Monkey",'
                .. '"family":"aspect","selfCast":true,"toggle":true}],"PALADIN":[{"key":"righteousfury",'
                .. '"name":"Righteous Fury","selfCast":true,"defaultNever":true}]},'
                .. '"familyAuras":{"aspect":["Aspect of the Cheetah","Aspect of the Pack"]},"removed":[]}')
            assert.are.equal(0, code, text)
            assert.is_truthy(out:find("toggle = true", 1, true))
            assert.is_truthy(out:find("defaultNever = true", 1, true))
            assert.is_truthy(out:find("aspect = { 5118 },", 1, true), out)
            assert.is_truthy(text:find("NOT FOUND  family aspect: 'Aspect of the Pack'", 1, true), text)
        end)

        it("refuses a toggle or defaultNever on a buff for others, a self-buff with a group version or rule, "
            .. "a family spell that is a buff's rank, and bad alsoNames (black)", function()
            for _, buffs in ipairs({
                '{"format":1,"classes":{"HUNTER":[{"key":"monkey","name":"Aspect of the Monkey","toggle":true}]}}',
                '{"format":1,"classes":{"PALADIN":[{"key":"rf","name":"Righteous Fury","defaultNever":true}]}}',
                '{"format":1,"classes":{"PALADIN":[{"key":"rf","name":"Righteous Fury","selfCast":true,'
                    .. '"defaultRule":"tanks"}]}}',
                '{"format":1,"classes":{"MAGE":[{"key":"ia","name":"Ice Armor","selfCast":true,'
                    .. '"group":["Frost Armor"]}]}}',
                '{"format":1,"classes":{"HUNTER":[{"key":"monkey","name":"Aspect of the Monkey","selfCast":true}]},'
                    .. '"familyAuras":{"aspect":["Aspect of the Monkey"]}}',
                '{"format":1,"classes":{"MAGE":[{"key":"ia","name":"Ice Armor","alsoNames":"Frost Armor"}]}}',
                '{"format":1,"classes":{"MAGE":[{"key":"ia","name":"Ice Armor","alsoNames":[""]}]}}',
                '{"format":1,"classes":{"MAGE":[{"key":"ia","name":"Ice Armor"}]},"familyAuras":["x"]}',
                '{"format":1,"classes":{"MAGE":[{"key":"ia","name":"Ice Armor"}]},"familyAuras":{"Bad Key":["x"]}}',
            }) do
                local code, text, out = run(buffs)
                assert.are.equal(1, code, buffs .. ": " .. text)
                assert.are.equal("KEEP", out, buffs)
            end
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
