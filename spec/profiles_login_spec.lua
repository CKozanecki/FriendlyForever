-- Spec: #519
-- A character with no profile record (#519): at its first login after 1.5.2,
-- while a shared profile is active, it gets a profile of its own, named after
-- it and copied from the live settings, and recorded as its choice (the
-- owner's decision of 24 Nov 2026, "B1"). It never joins the shared profile,
-- Default and every other profile are left as they were, and nothing stored
-- is put over the live settings unless a record says to, so a stale stored
-- Default never turns buff back, passers-by or requests off.
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

local function login(db, class, who, welcome)
    who = who or ME
    ns = wow.boot({ db = db, walkthrough = welcome, welcome = welcome, before = function(state)
        state.units.player = { name = who.name, surname = who.surname, id = who.id, isPlayer = true, level = ME.level }
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

local function copy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = copy(v) end
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

local function logout()
    wow.fire("PLAYER_LOGOUT")
    return _G.FriendlyForeverDB
end

describe("A character with no profile record (#519)", function()
    describe("white", function()
        for _, case in ipairs({
            { "1.5.1's file (schema 8)", 8, nil },
            { "1.5.2's file, another character recorded (schema 9)", 9,
                { characters = { ["Forever Realm:Bo-Reed"] = { profile = "Main" } }, characterLive = false } },
        }) do
            it("gets its own profile, a copy of the live settings, and keeps buff back on: " .. case[1], function()
                local db = mainActive(case[2], case[3])
                local before = copy(db.profiles)
                login(db)
                assert.are.equal("Ann", ns.Profiles.Active(), "its own, named after it")
                assert.are.equal("Ann", ns.db.characters[MY_KEY].profile, "recorded as its choice")
                assert.are.same(ALL_ON, switches(ns.db), "the live settings, never the stale Default's")
                assert.are.same(ALL_ON, switches(ns.db.profiles.Ann), "its profile is a copy of them")
                assert.are.same(before.Main, ns.db.profiles.Main, "Main is left as it was")
                assert.are.same(before.Default, ns.db.profiles.Default, "Default is left as it was")
                assert.is_false(ns.db.characterLive, "the live settings are its profile's, nobody's own")
                -- A stranger who buffs you is offered a buff back.
                wow.addUnit("nameplate1", { name = "Bob", surname = "Stone", id = "Bob-Stone", class = "PRIEST" })
                wow.gainBuff({ sourceUnit = "nameplate1", name = "Power Word: Fortitude", spellId = 10938 })
                local offer = ns.Offers.Current()
                assert.is_truthy(offer, "a buff back is offered")
                assert.are.equal("Bob-Stone", offer.name)
                assert.are.same({}, wow.errors)
            end)
        end

        it("editing its profile never changes the shared one, and it comes back to it at the next login", function()
            login(mainActive(9))
            local main = copy(ns.db.profiles.Main)
            ns.db.buffBack.passersBy = false
            ns.db.buffBack.buffModeKey = "G"
            local db = logout()
            assert.are.same(main, db.profiles.Main, "Main is as it was")
            assert.is_false(db.profiles.Ann.buffBack.passersBy, "the edit is in its own profile")
            -- As if another character left Main active: its settings live.
            db.activeProfile = "Main"
            db.buffBack, db.buff = copy(main.buffBack), copy(main.buff)
            login(db)
            assert.are.equal("Ann", ns.Profiles.Active(), "its record names its own")
            assert.are.same({ false, "G" }, { ns.db.buffBack.passersBy, ns.db.buffBack.buffModeKey })
            assert.are.same(ALL_ON, switches(ns.db.profiles.Main), "Main's switches are as they were")
        end)

        it("takes the next free name when its own is taken: Ann 2, Ann 3", function()
            local db = mainActive(9)
            db.profiles.Ann = { schemaVersion = 9 }
            db.profiles["Ann 2"] = { schemaVersion = 9 }
            login(db)
            assert.are.equal("Ann 3", ns.Profiles.Active())
            assert.are.same({ schemaVersion = 9 }, ns.db.profiles.Ann, "the other Ann's is left as it was")
        end)

        it("never takes Default's name, or the active profile's, for its own", function()
            local db = mainActive(9)
            login(db, nil, { name = "Default", surname = "Vale", id = "Default-Vale" })
            assert.are.equal("Default 2", ns.Profiles.Active(), "a character called Default")
            assert.is_false(ns.db.profiles.Default.buffBack.enabled, "Default is left as it was")
            db = mainActive(9)
            db.profiles.Default = nil -- Default not stored: the name is still never its own
            login(db, nil, { name = "Default", surname = "Vale", id = "Default-Vale" })
            assert.are.equal("Default 2", ns.Profiles.Active())
            assert.is_nil(ns.db.profiles.Default)
            db = mainActive(9, { activeProfile = "Ann" })
            db.profiles = nil -- Ann active but not stored: a damaged file
            login(db)
            assert.are.equal("Ann 2", ns.Profiles.Active())
            assert.are.same(ALL_ON, switches(ns.db))
        end)

        it("ends an import's undo, which was for the profile that was active", function()
            local db = mainActive(9)
            db.importUndo = { profile = "Main", settings = { schemaVersion = 9 }, ignoreAdded = {},
                who = "Forever Realm:Bo-Reed" }
            login(db)
            assert.is_nil(ns.db.importUndo)
        end)

        -- The architecture review of #524: the walkthrough and chat called every
        -- profile but Default shared, so a new character was told its own
        -- profile was "the same for each character on it".
        it("tells the new character its profile is its own, and shared only once another uses it", function()
            local function welcomed(extra)
                local db = mainActive(9, extra)
                db.walkthrough = { seen = 5, firstRun = false } -- the step about each character's own buffs: new
                login(db, nil, nil, true)
                local said = {}
                for _, line in ipairs(wow.printed) do
                    if line:find("buff settings", 1, true) then said[#said + 1] = line end
                end
                return ns.Walkthrough.Frame().stepText:GetText() or "", table.concat(said, "\n")
            end
            local text, chat = welcomed()
            assert.are.equal("Ann", ns.Profiles.Active())
            assert.is_false(ns.Profiles.SharedWithOthers())
            assert.is_truthy(text:find("This character uses the profile Ann, which only this character uses, so "
                .. "these settings are that profile's, and changing them changes no other character", 1, true), text)
            assert.is_falsy(text:find("shared profile Ann", 1, true), text)
            assert.is_truthy(chat:find("this character uses its own profile's buff settings", 1, true), chat)
            assert.is_falsy(chat:find("shared", 1, true), chat)
            -- Another character chose Main in 1.5.x and Ann went there too: shared.
            text, chat = welcomed({ charProfiles = { ["Ann-Vale"] = "Main", ["Bo-Reed"] = "Main" } })
            assert.are.equal("Main", ns.Profiles.Active())
            assert.is_true(ns.Profiles.SharedWithOthers())
            assert.is_truthy(text:find("This character uses the shared profile Main, so these settings are that "
                .. "profile's, the same for each character on it", 1, true), text)
            assert.is_truthy(chat:find("this character uses a shared profile's buff settings", 1, true), chat)
        end)

        it("calls a profile shared only when another character's record or 1.5.x choice names it", function()
            local bo = "Forever Realm:Bo-Reed"
            for _, case in ipairs({
                { "no other", {}, {}, false },
                { "another's record", { [bo] = { profile = "Main" } }, {}, true },
                { "another's record names another profile", { [bo] = { profile = "Alt" } }, {}, false },
                { "another's 1.5.x choice", {}, { ["Bo-Reed"] = "Main" }, true },
                -- The architecture review of #524: a record is the character's choice
                -- now; the 1.5.x one it was made from no longer counts.
                { "another's 1.5.x choice, since replaced by its record", { [bo] = { profile = "Default" } },
                    { ["Bo-Reed"] = "Main" }, false },
                { "only its own 1.5.x choice", {}, { ["Ann-Vale"] = "Main" }, false },
            }) do
                login(mainActive(9, { characters = case[2], charProfiles = case[3] }))
                ns.Profiles.Use("Main")
                assert.are.equal(case[4], ns.Profiles.SharedWithOthers(), case[1])
            end
            login(mainActive(9, { activeProfile = "Default", characters = { [bo] = { profile = "Default" } } }))
            assert.is_false(ns.Profiles.SharedWithOthers(), "Default is each character's own")
        end)

        it("at the cap of profiles it keeps the active one, and chat says why", function()
            local db = mainActive(9)
            for i = 1, 18 do db.profiles["P" .. i] = { schemaVersion = 9 } end -- 20 with Main and Default
            local before = copy(db.profiles)
            login(db)
            assert.are.equal("Main", ns.Profiles.Active(), "kept: no room for its own")
            assert.are.equal("Main", ns.db.characters[MY_KEY].profile)
            assert.are.same(ALL_ON, switches(ns.db))
            assert.are.same(before, ns.db.profiles, "nothing stored is changed")
            local said = false
            for _, line in ipairs(wow.printed) do
                if line:find("this character uses the profile Main, shared with your other characters", 1, true)
                    and line:find("the most profiles allowed (20)", 1, true) then
                    said = true
                end
            end
            assert.is_true(said, "chat says why")
            assert.are.same({}, wow.errors)
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

        it("a 1.5.x choice is still kept: it switches to that profile, and makes none", function()
            local db = mainActive(8, { charProfiles = { ["Ann-Vale"] = "Main" } })
            login(db)
            assert.are.equal("Main", ns.Profiles.Active())
            assert.is_nil(ns.db.profiles.Ann)
        end)

        it("logs the profile a new character gets", function()
            login(mainActive(9, { debug = true }))
            local found = false
            for _, line in ipairs(ns.db.diagLog) do
                if line:find("Forever Realm:Ann-Vale gets its own profile Ann, a copy of Main's live settings", 1, true)
                then
                    found = true
                end
            end
            assert.is_true(found, "the debug log names the profile made")
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
                assert.are.equal("Ann", ns.Profiles.Active(), label)
                assert.are.same(ALL_ON, switches(ns.db), label)
                assert.are.same({ 40, 22 }, { ns.db.buffBack.renewPercent, ns.db.guildLogin.delay }, label)
                assert.are.same({}, wow.errors, label)
            end
        end)

        it("a record naming a profile that is gone gets its own profile from the live settings", function()
            for _, junk in ipairs({ "nil", "x", { Default = { buffBack = { enabled = false } } } }) do
                local db = mainActive(9, { characters = { [MY_KEY] = { profile = "Gone" } } })
                db.profiles = junk ~= "nil" and junk or nil
                login(db)
                local label = type(junk) == "table" and "with Default stored" or tostring(junk)
                assert.are.equal("Ann", ns.Profiles.Active(), label)
                assert.are.same(ALL_ON, switches(ns.db), label)
                assert.are.equal("Ann", ns.db.characters[MY_KEY].profile, label)
                if type(junk) == "table" then
                    assert.is_false(ns.db.profiles.Default.buffBack.enabled, label .. ": Default as it was")
                end
            end
        end)

        it("a damaged 1.5.x list or character list is read as no choice: a profile of its own", function()
            for _, junk in ipairs({ 42, "x", { 1, 2 }, { ["Ann-Vale"] = 5 }, { ["Ann-Vale"] = "" } }) do
                login(mainActive(8, { charProfiles = junk, characters = junk }))
                assert.are.equal("Ann", ns.Profiles.Active(), tostring(junk))
                assert.are.same(ALL_ON, switches(ns.db), tostring(junk))
            end
        end)

        it("a damaged record of whose settings are live never keeps them as that character's", function()
            local bo = "Forever Realm:Bo-Reed"
            local db = mainActive(9, { characterLive = bo,
                characters = { [bo] = { settings = { buffModeKey = "B" } } } })
            db.buffBack.buffModeKey = "M"
            login(db)
            assert.are.equal("Ann", ns.Profiles.Active())
            assert.is_false(ns.db.characterLive, "the live settings are Ann's profile's")
            db = logout()
            assert.are.equal("B", db.characters[bo].settings.buffModeKey, "Bo's own are as they were")
        end)

        -- The architecture review of #524: a key that isn't a string, put in
        -- mid-session (another addon, a bad /run), is repaired before it is read.
        it("a character list damaged mid-session is repaired before it is read, never raising an error", function()
            login(mainActive(9, { characters = { ["Forever Realm:Bo-Reed"] = { profile = "Ann" } } }))
            for _, junk in ipairs({ 7, true, 1.5 }) do
                ns.db.characters[junk] = { profile = "Ann" }
                local ok, shared = pcall(ns.Profiles.SharedWithOthers)
                assert.is_true(ok, tostring(shared))
                assert.is_true(shared, tostring(junk) .. ": Bo's record still names Ann")
                assert.is_nil(ns.db.characters[junk], tostring(junk) .. ": repaired")
            end
            assert.are.same({}, wow.errors)
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

        local reach = { noRecord = 0, ownProfile = 0, kept = 0, toRecorded = 0, toDefault = 0, own = 0, gone = 0,
            damagedProfiles = 0 }

        for _, seed in ipairs({ 1, 5, 19, 519, 2026, 31337 }) do
            it("seed " .. seed .. ": never turns off a Favours switch or changes a stored profile, unless a record "
                .. "names another profile",
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
                        want = valid(listChoice) and listChoice or nil
                    end
                    local shared = want ~= nil and want ~= "Default"
                    local expected -- the switches after login, or nil: what a stored copy holds
                    local from
                    local own -- it gets a profile of its own, "Ann" (none of NAMES, and far from the cap)
                    local switching -- a record says to switch: the active profile is saved first
                    if not hasRecord and want == nil and active ~= "Default" then
                        expected, own = live, true
                        reach.ownProfile = reach.ownProfile + 1
                    elseif shared and want ~= active and stored[want] then
                        from, switching = stored[want], true
                        reach.toRecorded = reach.toRecorded + 1
                    elseif shared and active ~= "Default" then
                        expected = live
                        if want == active then reach.kept = reach.kept + 1 else reach.gone, own = reach.gone + 1, true end
                    elseif active ~= "Default" then
                        from, switching = stored.Default, true
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

                    local storedBefore = {}
                    for name, snap in pairs(stored) do storedBefore[name] = switches(snap) end

                    login(db)
                    assert.are.same({}, wow.errors, at)
                    assert.are.same(expected, switches(ns.db), at)
                    if own then
                        assert.are.equal("Ann", ns.Profiles.Active(), at .. ": its own profile")
                        assert.are.equal("Ann", ns.db.characters[MY_KEY].profile, at .. ": recorded")
                        assert.are.same(live, switches(ns.db.profiles.Ann), at .. ": a copy of the live settings")
                    end
                    -- Every stored profile is left as it was, but the one that was
                    -- active when a record says to switch (it is saved first).
                    for name, was in pairs(storedBefore) do
                        if not switching or name ~= active then
                            assert.are.same(was, switches(ns.db.profiles[name]), at .. ": " .. name .. " changed")
                        end
                    end
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
