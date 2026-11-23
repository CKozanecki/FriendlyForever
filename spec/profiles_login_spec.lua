-- Spec: #519
-- A character with no profile record (#519): at its first login after 1.5.2
-- it keeps the profile that was active, as 1.5.1 did, and records it as its
-- own. Nothing stored is put over the live settings unless a record says to,
-- so a stale stored Default never turns buff back, passers-by or requests
-- off.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local ns

local ME = { name = "Ann", surname = "Vale", id = "Ann-Vale", isPlayer = true, level = 60 }
local MY_KEY = "Forever Realm:Ann-Vale" -- written out here, not read from the addon
local INTELLECT = 10157

-- The Favours switches the owner's report named, and Buff Thanks: each
-- "section.field".
local SWITCHES = { { "buffBack", "enabled" }, { "buffBack", "passersBy" }, { "buffBack", "requests" },
    { "buff", "enabled" } }

local function login(db, class)
    ns = wow.boot({ db = db, before = function(state)
        state.units.player = { name = ME.name, surname = ME.surname, id = ME.id, isPlayer = true, level = ME.level }
        state.class = class or "MAGE"
        state.knownSpells = { [INTELLECT] = true }
    end })
    return ns
end

local function switches(db)
    local out = {}
    for _, s in ipairs(SWITCHES) do
        local section = db[s[1]]
        if type(section) == "table" then out[s[1] .. "." .. s[2]] = section[s[2]] end
    end
    return out
end

-- The owner's shape (#519): profiles in use, Main active and live, a stale
-- Default stored with buff back off, and no choice for this character.
local function mainActive(schema, extra)
    local db = { schemaVersion = schema, enabled = true, walkthrough = { seen = 99, firstRun = false },
        activeProfile = "Main",
        buffBack = { enabled = true, passersBy = true, requests = true },
        buff = { enabled = true },
        profiles = {
            Default = { schemaVersion = schema, buffBack = { enabled = false, passersBy = false, requests = false },
                buff = { enabled = false } },
            Main = { schemaVersion = schema, buffBack = { enabled = true, passersBy = true, requests = true },
                buff = { enabled = true } },
        } }
    for k, v in pairs(extra or {}) do db[k] = v end
    return db
end

local ALL_ON = { ["buffBack.enabled"] = true, ["buffBack.passersBy"] = true, ["buffBack.requests"] = true,
    ["buff.enabled"] = true }

describe("A character with no profile record (#519)", function()
    describe("white", function()
        for _, case in ipairs({
            { "1.5.1's file (schema 8)", 8, nil },
            { "1.5.2's file, another character recorded (schema 9)", 9,
                { characters = { ["Forever Realm:Bo-Reed"] = { profile = "Main" } }, characterLive = false } },
        }) do
            it("stays on the active profile, keeps buff back on and records it: " .. case[1], function()
                login(mainActive(case[2], case[3]))
                assert.are.equal("Main", ns.Profiles.Active(), "kept, as 1.5.1 did")
                assert.are.same(ALL_ON, switches(ns.db), "never the stale Default's switches")
                assert.are.equal("Main", ns.db.characters[MY_KEY].profile, "recorded as its own")
                assert.is_false(ns.db.characterLive, "the live settings are Main's, nobody's own")
                -- A stranger who buffs you is offered a buff back.
                wow.addUnit("nameplate1", { name = "Bob", surname = "Stone", id = "Bob-Stone", class = "PRIEST" })
                wow.gainBuff({ sourceUnit = "nameplate1", name = "Power Word: Fortitude", spellId = 10938 })
                local offer = ns.Offers.Current()
                assert.is_truthy(offer, "a buff back is offered")
                assert.are.equal("Bob-Stone", offer.name)
                assert.are.same({}, wow.errors)
            end)
        end

        it("keeps it at the next login, even when another character left another profile active", function()
            login(mainActive(9))
            ns.Profiles.New("Alt")
            ns.db.buffBack.passersBy = false -- Alt's own
            wow.fire("PLAYER_LOGOUT")
            local db = _G.FriendlyForeverDB
            db.activeProfile = "Alt" -- as if another character left it so
            db.characters[MY_KEY].profile = "Main"
            login(db)
            assert.are.equal("Main", ns.Profiles.Active(), "its record names Main")
            assert.are.same(ALL_ON, switches(ns.db), "Main's stored settings")
        end)

        it("a plain account (Default only) behaves as before: Default, its own settings, nothing switched", function()
            for _, profiles in ipairs({ false, true }) do
                local db = { schemaVersion = 9, enabled = true, walkthrough = { seen = 99, firstRun = false },
                    buffBack = { enabled = true, passersBy = true, requests = false, buffModeKey = "F" },
                    buff = { enabled = false } }
                if profiles then
                    db.activeProfile = "Default"
                    db.profiles = {}
                end
                login(db)
                local label = profiles and "with an empty profile list" or "with none"
                assert.are.equal("Default", ns.Profiles.Active(), label)
                assert.are.same({ ["buffBack.enabled"] = true, ["buffBack.passersBy"] = true,
                    ["buffBack.requests"] = false, ["buff.enabled"] = false }, switches(ns.db), label)
                local record = ns.db.characters[MY_KEY]
                assert.is_nil(record.profile, label .. ": its own, Default")
                assert.are.equal(MY_KEY, ns.db.characterLive, label .. ": the live settings are its own")
                assert.is_nil(next(ns.db.profiles), label .. ": no profile is stored until one is made")
                assert.are.same({}, wow.errors)
            end
        end)

        it("logs which profile a new character keeps", function()
            login(mainActive(9, { debug = true }))
            local found = false
            for _, line in ipairs(ns.db.diagLog) do
                if line:find("Ann-Vale is new here", 1, true) and line:find("its profile Main", 1, true) then
                    found = true
                end
            end
            assert.is_true(found, "the debug log names the profile kept")
        end)
    end)

    describe("black", function()
        it("a damaged or missing profiles table leaves the live settings untouched", function()
            for _, junk in ipairs({ "nil", "x", 42, true, { 1, 2 }, { Main = 5, Default = "x" } }) do
                local db = mainActive(9)
                db.profiles = junk ~= "nil" and junk or nil
                db.buffBack.renewPercent, db.guildLogin = 40, { delay = 22 }
                login(db)
                local label = tostring(junk)
                assert.are.equal("Main", ns.Profiles.Active(), label)
                assert.are.same(ALL_ON, switches(ns.db), label)
                assert.are.same({ 40, 22 }, { ns.db.buffBack.renewPercent, ns.db.guildLogin.delay }, label)
                assert.are.same({}, wow.errors, label)
            end
        end)

        it("a record naming a profile that is gone keeps the active one, and records it", function()
            for _, junk in ipairs({ "nil", "x", { Default = { buffBack = { enabled = false } } } }) do
                local db = mainActive(9, { characters = { [MY_KEY] = { profile = "Gone" } } })
                db.profiles = junk ~= "nil" and junk or nil
                login(db)
                local label = type(junk) == "table" and "with Default stored" or tostring(junk)
                assert.are.equal("Main", ns.Profiles.Active(), label)
                assert.are.same(ALL_ON, switches(ns.db), label)
                assert.are.equal("Main", ns.db.characters[MY_KEY].profile, label)
            end
        end)

        it("a damaged 1.5.x list or character list is read as no choice: the active profile is kept", function()
            for _, junk in ipairs({ 42, "x", { 1, 2 }, { ["Ann-Vale"] = 5 }, { ["Ann-Vale"] = "" } }) do
                login(mainActive(8, { charProfiles = junk, characters = junk }))
                assert.are.equal("Main", ns.Profiles.Active(), tostring(junk))
                assert.are.same(ALL_ON, switches(ns.db), tostring(junk))
            end
        end)

        it("a record that chose Default still goes back to it, the stored copy and all", function()
            login(mainActive(9, { characters = { [MY_KEY] = { profile = "Default" } } }))
            assert.are.equal("Default", ns.Profiles.Active(), "a record says to")
            assert.is_false(ns.db.buffBack.enabled, "Default's stored switches, as the record chose")
        end)
    end)

    describe("red: chaos over profile and record shapes", function()
        local NAMES = { "Default", "Main", "Alt", "Gone" }
        local JUNK = { 42, "x", true, { 1, 2 }, "" }
        local function pick(list) return list[random.random(#list)] end
        local function coin() return random.random(2) == 1 end
        local function drawSwitches()
            local out = {}
            for _, s in ipairs(SWITCHES) do out[s[1] .. "." .. s[2]] = coin() end
            return out
        end
        local function sections(values)
            local out = {}
            for _, s in ipairs(SWITCHES) do
                out[s[1]] = out[s[1]] or {}
                out[s[1]][s[2]] = values[s[1] .. "." .. s[2]]
            end
            return out
        end
        local function valid(name) return type(name) == "string" and name ~= "" end

        local reach = { noRecord = 0, kept = 0, toRecorded = 0, toDefault = 0, own = 0, gone = 0, damagedProfiles = 0 }

        for _, seed in ipairs({ 1, 5, 19, 519, 2026, 31337 }) do
            it("seed " .. seed .. ": never turns off a Favours switch unless a record names another profile",
                function()
                random.seed(seed)
                for round = 1, 30 do
                    local at = ("seed %d round %d"):format(seed, round)
                    local live = drawSwitches()
                    local db = sections(live)
                    db.schemaVersion = coin() and 9 or 8
                    db.enabled = true
                    db.walkthrough = { seen = 99, firstRun = false }
                    db.activeProfile = random.random(5) == 1 and pick(JUNK) or pick(NAMES)
                    -- The profiles: a table of snapshots (some damaged), or junk.
                    local stored = {}
                    if random.random(5) == 1 then
                        db.profiles = random.random(2) == 1 and pick(JUNK) or nil
                        reach.damagedProfiles = reach.damagedProfiles + 1
                    else
                        db.profiles = {}
                        for _, name in ipairs(NAMES) do
                            local roll = random.random(4)
                            if roll <= 2 then
                                local snap = sections(drawSwitches())
                                snap.schemaVersion = db.schemaVersion
                                db.profiles[name] = snap
                                stored[name] = snap
                            elseif roll == 3 then
                                db.profiles[name] = pick(JUNK)
                                -- A table is kept as a snapshot, with nothing in it.
                                if type(db.profiles[name]) == "table" then stored[name] = db.profiles[name] end
                            end
                        end
                    end
                    -- This character's record and 1.5.x's list: none, junk, or a choice.
                    local recordRoll = random.random(4)
                    local recordProfile
                    if recordRoll == 1 then
                        db.characters = pick(JUNK)
                    elseif recordRoll == 2 then
                        db.characters = { [MY_KEY] = pick(JUNK) }
                    elseif recordRoll == 3 then
                        recordProfile = random.random(4) == 1 and pick(JUNK) or pick(NAMES)
                        db.characters = { [MY_KEY] = { profile = recordProfile } }
                    end
                    -- A table is kept as a record, with no profile in it: its own.
                    local hasRecord = recordRoll == 3
                        or (recordRoll == 2 and type(db.characters[MY_KEY]) == "table")
                    local listChoice
                    if coin() then
                        listChoice = random.random(4) == 1 and pick(JUNK) or pick(NAMES)
                        db.charProfiles = { [ME.id] = listChoice }
                    end

                    -- The model, from the saved file alone.
                    local active = valid(db.activeProfile) and db.activeProfile or "Default"
                    local want
                    if hasRecord then
                        want = valid(recordProfile) and recordProfile or nil
                    else
                        reach.noRecord = reach.noRecord + 1
                        want = valid(listChoice) and listChoice or (active ~= "Default" and active or nil)
                    end
                    local shared = want ~= nil and want ~= "Default"
                    local expected -- the switches after login, or nil: what a stored copy holds
                    local from
                    if shared and want ~= active and stored[want] then
                        from = stored[want]
                        reach.toRecorded = reach.toRecorded + 1
                    elseif shared and active ~= "Default" then
                        expected = live
                        if want == active then reach.kept = reach.kept + 1 else reach.gone = reach.gone + 1 end
                    elseif active ~= "Default" then
                        from = stored.Default
                        expected = not from and live or nil
                        reach.toDefault = reach.toDefault + 1
                    else
                        expected = live
                        reach.own = reach.own + 1
                    end
                    if from then
                        expected = {}
                        for _, s in ipairs(SWITCHES) do
                            local name = s[1] .. "." .. s[2]
                            local section = from[s[1]]
                            if type(section) == "table" then expected[name] = section[s[2]] else expected[name] = live[name] end
                        end
                    end

                    login(db)
                    assert.are.same({}, wow.errors, at)
                    assert.are.same(expected, switches(ns.db), at)
                    if not from then
                        for name, on in pairs(live) do
                            assert.is_false(on and ns.db[name:match("^(%a+)")][name:match("%.(%a+)$")] ~= true,
                                at .. ": " .. name .. " turned off with no record saying to")
                        end
                    end
                end
            end)
        end

        it("the seeds reach every path", function()
            for path, count in pairs(reach) do assert.is_true(count > 0, path .. " never ran") end
        end)
    end)
end)
