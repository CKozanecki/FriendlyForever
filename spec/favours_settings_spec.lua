-- Spec: #491
-- Favours and saved settings: the tab moved nothing in the saved file, so
-- settings saved by 1.4.4 load with every edited line, key, style, fallback
-- and switch kept, once and for good (a second load changes nothing); partial
-- and damaged files load, each damaged field healing to its default; and a
-- storm of the Favours tab's controls and buff mode's (on the Buffs tab),
-- with their sections damaged mid-session, never raises an error and leaves
-- every field valid. The expected values
-- are worked out here from the field kinds below, not by the code under test.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

-- A seeded source of whole numbers (spec/support/random.lua's sequence).
local function rngFor(seed)
    random.seed(seed)
    return { int = function(_, a, b) return random.random(a, b) end }
end

local SEEDS = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20 }

-- The Favours tab's fields, by kind: a switch, a number and its limits, one
-- of a set, or text. (1.4.4's Buff Thanks and Buff Back tabs, and passers-by.)
local FIELDS = {
    buff = {
        enabled = { "bool" }, listBuffNames = { "bool" }, quietInCities = { "bool" }, receipts = { "bool" },
        delay = { "number", 0, 60 }, repeatCooldown = { "number", 0, 3600 },
        thankStyle = { "set", { "message", "whisper", "emote", "both" } },
        fallback = { "set", { "say", "emote", "none" } },
        unknownName = { "name" },
    },
    buffBack = {
        enabled = { "bool" }, sayLine = { "bool" }, showInCities = { "bool" }, requests = { "bool" },
        passersBy = { "bool" }, autoOnJoin = { "bool" }, autoOnDeath = { "bool" }, autoOnBuffed = { "bool" },
        autoOnMissing = { "bool" }, autoOnCampfire = { "bool" }, autoOffPull = { "bool" }, autoOffDone = { "bool" },
        owedMinutes = { "number", 1, 60 }, renewPercent = { "number", 0, 90 },
        autoOffMinutes = { "number", 0, 30 }, topUpMinutes = { "number", 0, 15 },
        buffModeKey = { "set", { "MOUSEWHEELUP", "MOUSEWHEELDOWN", "BUTTON4", "CTRL-F", "SHIFT-MOUSEWHEELUP" } },
    },
}
-- 1.4.4's defaults for those fields, written out: a damaged field heals to these.
local DEFAULTS = {
    buff = { enabled = true, listBuffNames = true, quietInCities = true, receipts = true, delay = 4,
        repeatCooldown = 180, thankStyle = "message", fallback = "say", unknownName = "friend" },
    buffBack = { enabled = true, sayLine = false, showInCities = false, requests = false, passersBy = false,
        autoOnJoin = true, autoOnDeath = true, autoOnBuffed = true, autoOnMissing = true, autoOnCampfire = true,
        autoOffPull = true, autoOffDone = true, owedMinutes = 10, renewPercent = 70, autoOffMinutes = 5,
        topUpMinutes = 5, buffModeKey = "MOUSEWHEELUP" },
}
local JUNK = { "junk", 42.5, -7, 1e12, {}, { 1 }, true, false, 0 / 0, math.huge, -math.huge, "" }

local function sorted(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
end

-- A good value of a field's kind, chosen by rng.
local function goodValue(kind, rng)
    if kind[1] == "bool" then return rng:int(1, 2) == 1 end
    if kind[1] == "number" then return rng:int(kind[2], kind[3]) end
    if kind[1] == "set" then return kind[2][rng:int(1, #kind[2])] end
    return ({ "pal", "buddy", "Friend", "mate" })[rng:int(1, 4)]
end

-- What a saved value loads as, worked out from its kind alone.
local function expected(kind, value, default)
    if kind[1] == "bool" then
        if type(value) == "boolean" then return value end
        return default
    end
    if kind[1] == "number" then
        if type(value) ~= "number" or value ~= value then return default end
        return math.max(kind[2], math.min(kind[3], math.floor(value)))
    end
    if kind[1] == "set" then
        for _, ok in ipairs(kind[2]) do if ok == value then return value end end
        return default
    end
    -- A name: text kept (short text here), anything else the default.
    if type(value) == "string" then return value end
    return default
end

-- Edited lines: each a different, non-default line.
local function editedLines(prefix, rng)
    local out = {}
    for i = 1, 30 do out[i] = ("%s line %d, %d"):format(prefix, i, rng:int(1, 1000)) end
    return out
end

-- A whole 1.4.4 saved file: every Favours field set to a good value, edited
-- lines, a key; walkthrough version 3 (1.4.4's), schema 8.
local function file144(rng)
    local db = { schemaVersion = 8, enabled = true, walkthrough = { seen = 3, firstRun = false },
        buff = { messages = editedLines("thanks", rng) },
        buffBack = { messages = editedLines("landed", rng), whoChoice = "kept", unlocked = true,
            position = { point = "TOP", x = 12, y = -40 } } }
    for section, fields in pairs(FIELDS) do
        for _, field in ipairs(sorted(fields)) do db[section][field] = goodValue(fields[field], rng) end
    end
    return db
end

describe("Favours and saved settings (#491)", function()
    local ns

    before_each(function() ns = wow.boot() end)

    local function load(saved) return ns.Config.Load(saved) end

    describe("1.4.4's saved settings (white)", function()
        it("load with every edited line, key, style, fallback and switch kept", function()
            for _, seed in ipairs(SEEDS) do
                local rng = rngFor(seed)
                local saved = file144(rng)
                local given = ns.Util.DeepCopy(saved)
                local db = load(saved)
                for section, fields in pairs(FIELDS) do
                    for field in pairs(fields) do
                        assert.are.equal(given[section][field], db[section][field],
                            ("seed %d: %s.%s"):format(seed, section, field))
                    end
                    assert.are.same(given[section].messages, db[section].messages, section .. " lines")
                end
                assert.are.same(given.buffBack.position, db.buffBack.position)
                assert.is_true(db.buffBack.unlocked)
                assert.are.equal("kept", db.buffBack.whoChoice)
                assert.are.equal(3, db.walkthrough.seen, "the walkthrough's What's new waits for the player")
            end
        end)

        it("load once: loading the loaded file again changes nothing", function()
            for _, seed in ipairs(SEEDS) do
                local db = load(file144(rngFor(seed)))
                local once = ns.Util.DeepCopy(db)
                assert.are.same(once, load(db), "seed " .. seed)
            end
        end)

        it("move no field and add none: each section keeps its name, and no favours section appears", function()
            local db = load(file144(rngFor(1)))
            assert.is_nil(db.favours)
            assert.is_table(db.buff)
            assert.is_table(db.buffBack)
            assert.are.equal(ns.Config.SCHEMA_VERSION, db.schemaVersion)
            assert.are.equal(8, ns.Config.SCHEMA_VERSION, "no migration: the schema is 1.4.4's")
        end)

        it("show on the Favours tab as they were saved", function()
            local saved = file144(rngFor(7))
            ns = wow.boot({ db = ns.Util.DeepCopy(saved) })
            local w = ns.Options.widgets
            ns.Options.Open()
            wow.run(w.tabs.favours, "OnClick")
            assert.are.equal(saved.buff.enabled, w.thankEnabled:GetChecked())
            assert.are.equal(tostring(saved.buff.delay), w.steppers.thankDelay.box:GetText())
            assert.are.equal(saved.buffBack.sayLine, w.sayLine:GetChecked())
            assert.are.equal(saved.buffBack.passersBy, w.passersBy:GetChecked())
            assert.are.equal(saved.buffBack.requests, w.buffRequests:GetChecked())
            for i = 1, 30 do assert.are.equal(saved.buff.messages[i], w.edits[i]:GetText()) end
            wow.run(w.linesTabs.buffBack, "OnClick")
            for i = 1, 30 do assert.are.equal(saved.buffBack.messages[i], w.edits[i]:GetText()) end
            -- Buff mode's, on the Buffs tab.
            wow.run(w.tabs.buffs, "OnClick")
            for _, field in ipairs(ns.Options.AUTO_SWITCHES) do
                assert.are.equal(saved.buffBack[field], w.auto[field]:GetChecked(), field)
            end
            assert.are.equal(tostring(saved.buffBack.autoOffMinutes), w.steppers.autoOffMinutes.box:GetText())
            assert.are.equal(tostring(saved.buffBack.topUpMinutes), w.steppers.topUpMinutes.box:GetText())
            assert.is_truthy(w.buffModeKey:GetText():find(saved.buffBack.buffModeKey, 1, true))
        end)

        it("a settings line in 1.4.4's form imports with every Favours setting and line", function()
            -- 1.4.4's export: the file's sections as they are, encoded (Profiles.Export).
            local saved = load(file144(rngFor(3)))
            local settings = { schemaVersion = 8, buff = ns.Util.DeepCopy(saved.buff),
                buffBack = ns.Util.DeepCopy(saved.buffBack) }
            settings.buffBack.position, settings.buffBack.unlocked = nil, nil -- this screen's own
            local line = assert(ns.Serialize.Encode({ v = 1, settings = settings }))
            assert.is_true(ns.Profiles.Import(line))
            for section, fields in pairs(FIELDS) do
                for field in pairs(fields) do
                    assert.are.equal(saved[section][field], ns.db[section][field], section .. "." .. field)
                end
                assert.are.same(saved[section].messages, ns.db[section].messages, section .. " lines")
            end
        end)
    end)

    describe("partial and damaged saved settings (black, red)", function()
        it("a partial file keeps what it has and fills the rest with the defaults", function()
            for _, seed in ipairs(SEEDS) do
                local rng = rngFor(seed)
                local full = file144(rng)
                local saved = { schemaVersion = rng:int(1, 8) == 1 and nil or 8, buff = {}, buffBack = {} }
                local kept = {}
                for section, fields in pairs(FIELDS) do
                    kept[section] = {}
                    for _, field in ipairs(sorted(fields)) do
                        if rng:int(1, 2) == 1 then
                            saved[section][field] = full[section][field]
                            kept[section][field] = true
                        end
                    end
                end
                if rng:int(1, 3) == 1 then saved.buff = nil; kept.buff = {} end
                local db = load(saved)
                for section, fields in pairs(FIELDS) do
                    for field in pairs(fields) do
                        local want = DEFAULTS[section][field]
                        if kept[section][field] then want = full[section][field] end
                        assert.are.equal(want, db[section][field], ("seed %d: %s.%s"):format(seed, section, field))
                    end
                end
            end
        end)

        it("a damaged field heals to its default, a clamped number to its limit, and the rest stay", function()
            for _, seed in ipairs(SEEDS) do
                local rng = rngFor(seed)
                local saved = file144(rng)
                local want = {}
                for section, fields in pairs(FIELDS) do
                    want[section] = {}
                    for _, field in ipairs(sorted(fields)) do
                        local value = saved[section][field]
                        if rng:int(1, 3) == 1 then
                            value = JUNK[rng:int(1, #JUNK)]
                            saved[section][field] = value
                        end
                        want[section][field] = expected(fields[field], value, DEFAULTS[section][field])
                    end
                end
                local db = load(saved)
                for section, fields in pairs(FIELDS) do
                    for field in pairs(fields) do
                        assert.are.equal(want[section][field], db[section][field],
                            ("seed %d: %s.%s"):format(seed, section, field))
                    end
                end
            end
        end)

        it("a damaged section, damaged lines or a damaged walkthrough version load as their defaults", function()
            for _, junk in ipairs(JUNK) do
                local db = load({ schemaVersion = 8, buff = junk, buffBack = { messages = junk },
                    walkthrough = { seen = junk } })
                for field, value in pairs(DEFAULTS.buff) do assert.are.equal(value, db.buff[field], field) end
                assert.are.equal(30, #db.buffBack.messages)
                for _, line in ipairs(db.buffBack.messages) do assert.is_string(line) end
                assert.is_number(db.walkthrough.seen)
            end
        end)
    end)

    describe("a storm on the Favours tab, and buff mode's rows on the Buffs tab (red)", function()
        it("random clicks, numbers, lines and sub-tabs, with sections damaged mid-session, never raise an error", function()
            for _, seed in ipairs(SEEDS) do
                local rng = rngFor(seed)
                ns = wow.boot({ db = file144(rng) })
                local w = ns.Options.widgets
                ns.Options.Open()
                wow.run(w.tabs.favours, "OnClick")
                local boxes = { w.thankEnabled, w.listNames, w.receipts, w.quiet, w.offerEnabled, w.sayLine,
                    w.buffRequests, w.passersBy, w.showInCities }
                -- Buff mode's controls are on the Buffs tab (#491): clicked there, then
                -- back to Favours.
                local onBuffs = { autoOffMinutes = true, topUpMinutes = true }
                for _, field in ipairs(ns.Options.AUTO_SWITCHES) do
                    boxes[#boxes + 1] = w.auto[field]
                    onBuffs[w.auto[field]] = true
                end
                local steppers = { "thankDelay", "thankRepeat", "owedMinutes", "renewPercent", "autoOffMinutes",
                    "topUpMinutes" }
                local function on(control, act)
                    if onBuffs[control] then wow.run(w.tabs.buffs, "OnClick") end
                    act()
                    if onBuffs[control] then wow.run(w.tabs.favours, "OnClick") end
                end
                for step = 1, 60 do
                    local where = ("seed %d, step %d"):format(seed, step)
                    local roll = rng:int(1, 9)
                    local ok, err = pcall(function()
                        if roll == 1 then
                            local box = boxes[rng:int(1, #boxes)]
                            local checked = rng:int(1, 2) == 1
                            on(box, function()
                                box:SetChecked(checked)
                                wow.run(box, "OnClick")
                            end)
                        elseif roll == 2 then
                            local name = steppers[rng:int(1, #steppers)]
                            local s = w.steppers[name]
                            local typed = tostring(rng:int(-50, 5000))
                            on(name, function()
                                s.box:SetText(typed)
                                wow.run(s.box, "OnEditFocusLost")
                            end)
                        elseif roll == 3 then
                            local i = rng:int(1, 30)
                            w.edits[i]:SetText("line " .. step)
                            wow.run(w.edits[i], "OnTextChanged", true)
                        elseif roll == 4 then
                            wow.run(w.linesTabs[rng:int(1, 2) == 1 and "buff" or "buffBack"], "OnClick")
                        elseif roll == 5 then
                            -- Another addon or a bad /run damages a section or a field.
                            local section = rng:int(1, 2) == 1 and "buff" or "buffBack"
                            if rng:int(1, 2) == 1 then
                                ns.db[section] = JUNK[rng:int(1, #JUNK)]
                            elseif type(ns.db[section]) == "table" then
                                local names = sorted(FIELDS[section])
                                ns.db[section][names[rng:int(1, #names)]] = JUNK[rng:int(1, #JUNK)]
                            end
                            wow.advance(2) -- past the repair's once-a-second limit
                        elseif roll == 6 then
                            local rows = rng:int(1, 2) == 1 and w.thankStyle.rows or w.fallback.rows
                            wow.run(rows[rng:int(1, #rows)], "OnClick")
                        elseif roll == 7 then
                            wow.run(w.tabs[ns.Options.TABS[rng:int(1, #ns.Options.TABS)]], "OnClick")
                            wow.run(w.tabs.favours, "OnClick")
                        elseif roll == 8 then
                            wow.run(rng:int(1, 2) == 1 and w.loadFantasy or w.loadCasual, "OnClick")
                        else
                            ns.Options.Refresh()
                        end
                    end)
                    assert.is_true(ok, where .. ": " .. tostring(err))
                end
                -- Whatever was damaged heals as the tab fills: every field valid by its kind.
                ns.Options.Refresh()
                for section, fields in pairs(FIELDS) do
                    assert.is_table(ns.db[section], "seed " .. seed .. ": " .. section)
                    for field, kind in pairs(fields) do
                        local value = ns.db[section][field]
                        local ok = expected(kind, value, {}) == value
                        if kind[1] == "set" and section == "buffBack" then ok = ns.BuffMode.IsValidKey(value) end
                        assert.is_true(ok, ("seed %d: %s.%s = %s"):format(seed, section, field, tostring(value)))
                    end
                    assert.are.equal(30, #ns.db[section].messages)
                end
            end
        end)
    end)
end)
