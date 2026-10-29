-- Spec: #52
-- Phase 1 under damage and chaos: the ignore list, snooze, profiles,
-- export/import with undo and the favour ledger, damaged mid-session (black)
-- and in seeded random storms (red). Mid-session damage stands for another
-- addon or a bad /run writing nonsense into the saved settings.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local ME = { name = "Nikki", surname = "Shifts", id = "Nikki-Shifts", isPlayer = true }
local GUILD = { "Ann-Vale", "Bob-Stone", "Cid-Moss", "Dot-Reed" }
local STRANGERS = { "Eve-Hart", "Fay-Lark", "Gus-Pike", "Hal-Rook", "Ivy-Wren" }

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

local function boot(db, clock)
    local ns = wow.boot({ db = db, before = function(state)
        state.units.player = { name = ME.name, surname = ME.surname, id = ME.id, isPlayer = true }
        state.guildRoster = GUILD
        if clock then state.clock = clock end
    end })
    wow.fire("GUILD_ROSTER_UPDATE")
    ns.db.guildLogin.messages = { "GL {name}" }
    ns.db.buff.messages = { "TY {name}" }
    return ns
end

local function online(full)
    wow.systemMessage("|Hplayer:" .. full .. "|h[" .. full .. "]|h has come online.")
end

local function buffedBy(full, token)
    local first, surname = full:match("^(%a+)-(%a+)$")
    wow.addUnit(token or "nameplate1", { name = first, surname = surname, id = full })
    wow.gainBuff({ sourceUnit = token or "nameplate1", name = "Arcane Intellect" })
end

local function printedHas(fragment)
    for _, line in ipairs(wow.printed) do
        if line:find(fragment, 1, true) then return true end
    end
    return false
end

describe("Phase 1 settings damaged mid-session (black)", function()
    local ns

    before_each(function() ns = boot() end)

    -- The things a player does with phase 1, all at once: none may error.
    local function useEverything()
        online("Ann-Vale")
        buffedBy("Eve-Hart")
        wow.advance(30)
        wow.keyDown()
        for _, command in ipairs({ "ignore Bob Stone", "ignore", "unignore Bob Stone", "snooze 5", "snooze off",
            "ledger", "profile", "profile new P1", "profile use Default", "profile delete P1", "export",
            "import undo", "status", "report" }) do
            slash(command)
        end
        ns.Options.Open()
        ns.Options.Refresh()
        wow.fire("PLAYER_LOGOUT")
    end

    it("an ignore list damaged into a non-table raises no error and is repaired, empty", function()
        for _, damage in ipairs({ 42, "x", true }) do
            ns = boot()
            ns.db.ignore = damage
            useEverything()
            assert.are.same({}, wow.errors, tostring(damage))
            assert.are.same({}, ns.db.ignore, "repaired, empty: the names can't be read")
            assert.are.same({ "GL Ann" }, wow.sentTo("GUILD"), "greeting still works")
        end
    end)

    it("a damaged ignore entry is skipped in the list, without an error, and dropped at the next load", function()
        ns.Ignore.Add("Ann-Vale")
        ns.db.ignore[7] = "x"
        ns.db.ignore["bob-stone"] = 42
        ns.db.ignore["cid-moss"] = { "Cid-Moss" }
        useEverything()
        assert.are.same({}, wow.errors)
        assert.are.same({ "Ann Vale" }, ns.Ignore.List())
        assert.are.same({}, wow.sentTo("GUILD"), "Ann is still ignored")
        ns = boot(_G.FriendlyForeverDB)
        assert.are.same({ ["ann-vale"] = "Ann-Vale" }, ns.db.ignore)
    end)

    it("removes an ignored name whose entry was damaged", function()
        ns.Ignore.Add("Bob-Stone")
        ns.db.ignore["bob-stone"] = 42
        slash("unignore Bob Stone")
        assert.are.same({}, wow.errors)
        assert.is_true(printedHas("Bob Stone is off your ignore list."))
        assert.is_false(ns.Ignore.Has("Bob-Stone"))
    end)

    it("a snooze damaged into something that isn't a time reads as awake, without an error", function()
        for _, damage in ipairs({ "x", true, {}, 0 / 0 }) do
            ns = boot()
            ns.db.snoozeUntil = damage
            assert.is_nil(ns.Announcer.SnoozeLeft(), tostring(damage))
            assert.is_nil(ns.db.snoozeUntil, tostring(damage) .. ": repaired as soon as it's read")
            ns.db.snoozeUntil = damage
            useEverything()
            assert.are.same({}, wow.errors, tostring(damage))
            assert.are.same({ "GL Ann" }, wow.sentTo("GUILD"), tostring(damage))
            assert.is_nil(ns.db.snoozeUntil, tostring(damage))
        end
    end)

    it("a snooze damaged far into the future lasts at most a day", function()
        for _, damage in ipairs({ 1e12, math.huge }) do
            ns = boot()
            ns.db.snoozeUntil = damage
            assert.is_true(ns.Announcer.SnoozeLeft() <= ns.Config.SNOOZE_MAX_SECONDS, tostring(damage))
            wow.advance(ns.Config.SNOOZE_MAX_SECONDS + 1)
            online("Ann-Vale")
            wow.advance(30)
            assert.are.same({ "GL Ann" }, wow.sentTo("GUILD"), tostring(damage))
        end
    end)

    it("profile data damaged mid-session raises no error, and is repaired", function()
        local damages = {
            profiles = { 42, "x", true, { 1, 2 }, { P1 = 5 } },
            activeProfile = { 42, true, {}, "", string.rep("p", 40) },
            charProfiles = { 42, "x", true },
            importUndo = { 42, "x", true, { profile = "Default" }, { profile = "Default", settings = {}, ignoreAdded = 3 } },
        }
        for field, values in pairs(damages) do
            for _, damage in ipairs(values) do
                ns = boot()
                slash("profile new P1")
                ns.db[field] = damage
                useEverything()
                local label = field .. " = " .. tostring(damage)
                assert.are.same({}, wow.errors, label)
                local list = ns.Profiles.List()
                local active = ns.Profiles.Active()
                local found = false
                for _, name in ipairs(list) do found = found or name == active end
                assert.is_true(found, label .. ": the active profile is listed")
                assert.are.equal("table", type(ns.db.profiles), label)
                assert.are.equal("table", type(ns.db.charProfiles), label)
            end
        end
    end)

    it("a damaged profile name falls back to Default, as at load", function()
        slash("profile new P1")
        ns.db.activeProfile = 42
        assert.are.equal("Default", ns.Profiles.Active())
    end)

    it("a damaged import undo is dropped: nothing to undo", function()
        ns.Ignore.Add("Ann-Vale")
        local line = assert(ns.Profiles.Export())
        ns = boot()
        assert.is_true(ns.Profiles.Import(line))
        ns.db.importUndo = { profile = "Default", settings = 5 }
        assert.is_false(ns.Profiles.CanUndoImport())
        slash("import undo")
        assert.are.same({}, wow.errors)
        assert.is_true(printedHas("there's no import to undo"))
        assert.is_true(ns.Ignore.Has("Ann-Vale"), "the imported name stays")
    end)

    it("an import undo without its profile or settings is dropped", function()
        for _, damage in ipairs({ { settings = {}, ignoreAdded = {} }, { profile = "Default", ignoreAdded = {} } }) do
            ns = boot()
            ns.db.importUndo = damage
            assert.is_false(ns.Profiles.CanUndoImport())
            assert.is_nil(ns.db.importUndo)
        end
    end)

    it("an import undo that lost the names it added still undoes the settings, as at load", function()
        ns.db.importUndo = { profile = "Default", settings = { guildLogin = { delay = 9 } } }
        slash("import undo")
        assert.are.same({}, wow.errors)
        assert.are.equal(9, ns.db.guildLogin.delay)
    end)

    it("an import made while the profile name is damaged can still be undone", function()
        ns.Ignore.Add("Ann-Vale")
        local line = assert(ns.Profiles.Export())
        ns = boot()
        ns.db.activeProfile = 42
        assert.is_true(ns.Profiles.Import(line))
        assert.is_true(ns.Ignore.Has("Ann-Vale"))
        slash("import undo")
        assert.is_true(printedHas("your settings from before the import are back."))
        assert.is_false(ns.Ignore.Has("Ann-Vale"))
    end)

    describe("each thing a player does, done first after the damage", function()
        local DAMAGE = {
            ignore = { 42, "x", true },
            snoozeUntil = { "x", true, {}, 0 / 0 },
            profiles = { 42, "x", true, { 1, 2 }, { P1 = 5 }, { [1] = {} } },
            activeProfile = { 42, true, {}, "", string.rep("p", 40) },
            charProfiles = { 42, "x", true },
            importUndo = { 42, "x", true, { profile = "P1" }, { profile = "P1", settings = {}, ignoreAdded = 3 },
                { profile = "P1", ignoreAdded = {} }, { settings = {}, ignoreAdded = {} },
                { profile = "P1", settings = {} } },
        }
        local line
        local DOES = {
            { "a guildmate logs in", function() online("Bob-Stone") wow.advance(30) end },
            { "a stranger's buff is thanked", function() buffedBy("Eve-Hart") wow.advance(30) wow.keyDown() end },
            { "/friendly ignore <name>", function() slash("ignore Cid Moss") end },
            { "/friendly unignore <name>", function() slash("unignore Ann Vale") end },
            { "/friendly ignore", function() slash("ignore") end },
            { "/friendly snooze", function() slash("snooze 5") end },
            { "/friendly status", function() slash("status") end },
            { "/friendly export", function() slash("export") end },
            { "an import", function()
                slash("import")
                ns.Window.Frame().box:SetText(line)
                wow.run(ns.Window.Frame().accept, "OnClick")
            end },
            { "/friendly import undo", function() slash("import undo") end },
            { "/friendly profile", function() slash("profile") end },
            { "/friendly profile new", function() slash("profile new P2") end },
            { "/friendly profile use", function() slash("profile use Default") end },
            { "/friendly profile delete", function() slash("profile delete Default") end },
            { "logging out", function() wow.fire("PLAYER_LOGOUT") end },
            { "logging in", function() wow.reloadInPlace(true) end },
            { "the General options page", function() ns.Options.Open() ns.Options.Refresh() end },
            { "the minimap tooltip", function() ns.Minimap.Refresh() end },
        }

        it("raises no Lua error", function()
            ns.Ignore.Add("Bob-Stone")
            line = assert(ns.Profiles.Export())
            for field, values in pairs(DAMAGE) do
                for _, damage in ipairs(values) do
                    for _, does in ipairs(DOES) do
                        ns = boot()
                        ns.Ignore.Add("Ann-Vale")
                        slash("profile new P1")
                        assert(ns.Profiles.Import(line)) -- something to undo
                        ns.db[field] = damage
                        does[2]()
                        assert.are.same({}, wow.errors, ("%s = %s, then %s"):format(field, tostring(damage), does[1]))
                    end
                end
            end
        end)
    end)
end)

describe("The favour ledger damaged mid-session (black)", function()
    local ns

    before_each(function() ns = boot() end)

    it("a favour waiting for its thanks when the ledger is lost is counted again, with its thanks", function()
        buffedBy("Eve-Hart")
        ns.db.ledger = 42
        wow.advance(30)
        wow.keyDown()
        assert.are.same({ "TY Eve" }, wow.sentTo("SAY"))
        local s = ns.Ledger.Summary()
        assert.are.same({ 1, 1, 1 }, { s.received, s.thanked, s.stored })
        assert.are.same({ 1, 1 }, { s.todayReceived, s.todayThanked })
    end)

    it("a favour returned after the ledger is lost is counted again, with its return", function()
        local entry = ns.Ledger.Received("Eve-Hart", "Thorns")
        ns.db.ledger = nil
        ns.Ledger.Returned(entry, "Mark of the Wild")
        local s = ns.Ledger.Summary()
        assert.are.same({ 1, 1, 1 }, { s.received, s.returned, s.stored })
    end)

    it("a favour still in the ledger isn't counted twice", function()
        local entry = ns.Ledger.Received("Eve-Hart", "Thorns")
        ns.db.ledger.totals.thanked = "x" -- repaired, entries kept
        ns.Ledger.Settle(entry, true)
        ns.Ledger.Returned(entry, "Mark of the Wild")
        local s = ns.Ledger.Summary()
        assert.are.same({ 1, 1, 1, 1 }, { s.received, s.thanked, s.returned, s.stored })
    end)

    it("a cleared favour's thanks still aren't counted", function()
        local entry = ns.Ledger.Received("Eve-Hart", "Thorns")
        slash("ledger clear")
        ns.Ledger.Settle(entry, true)
        local s = ns.Ledger.Summary()
        assert.are.same({ 0, 0, 0 }, { s.received, s.thanked, s.stored })
    end)

    it("damaged totals start again from today's counts, never below them", function()
        buffedBy("Eve-Hart")
        wow.advance(30)
        wow.keyDown()
        ns.db.ledger.totals = "x"
        local s = ns.Ledger.Summary()
        assert.are.same({ 1, 1 }, { s.received, s.thanked })
        ns.db.ledger.totals = { received = 5, thanked = 0, returned = 0 }
        s = ns.Ledger.Summary()
        assert.are.same({ 5, 0 }, { s.received, s.thanked }, "healthy totals are left alone")
        ns = boot({ ledger = { totals = { received = 0, thanked = 0, returned = 0 },
            today = { day = "2026-10-26", received = 3, thanked = 2, returned = 1 } } })
        s = ns.Ledger.Summary()
        assert.are.same({ 3, 2, 1 }, { s.received, s.thanked, s.returned }, "a saved file's totals are raised to today's too")
    end)
end)

describe("Phase 1 chaos (red tests)", function()
    local DISPLAY = {}
    for _, full in ipairs(GUILD) do DISPLAY[full] = full:gsub("-", " ") end
    for _, full in ipairs(STRANGERS) do DISPLAY[full] = full:gsub("-", " ") end
    local BY_FIRST = {}
    for full in pairs(DISPLAY) do BY_FIRST[full:match("^(%a+)")] = full end
    local EVERYONE = {}
    for _, full in ipairs(GUILD) do EVERYONE[#EVERYONE + 1] = full end
    for _, full in ipairs(STRANGERS) do EVERYONE[#EVERYONE + 1] = full end
    local PROFILE_NAMES = { "Default", "P1", "P2", "P3" }

    local function sorted(set)
        local out = {}
        for k in pairs(set) do out[#out + 1] = k end
        table.sort(out)
        return out
    end

    -- One seeded storm. The test keeps its own model of what the player did
    -- (who they ignored, when they snoozed, which profiles they made), worked
    -- out from the storm's actions and the simulated client, never from the
    -- addon. After each step the addon must agree with it, must have sent
    -- nothing it shouldn't, and must have raised no Lua error.
    local function storm(seed, steps)
        random.seed(seed)
        local ns = boot()
        local m = {
            enabled = true,
            ignored = {},      -- [full name] = true
            snoozeUntil = nil, -- time() it ends
            profiles = {},     -- [name] = true: the profiles stored
            active = "Default",
            charLast = nil,    -- the profile this character used last
            undo = nil,        -- { profile, added = { [full name] = true } }
            saved = nil,       -- { line, ignored } from the last export
        }
        local seen = { greeted = 0, thanked = 0, ignoredOnline = 0, imports = 0, undos = 0, switches = 0,
            reloads = 0, snoozedSteps = 0 }
        local thanksSinceClear = 0
        local sentBefore = 0

        local function snoozed() return m.snoozeUntil ~= nil and m.snoozeUntil > _G.time() end
        local function rememberChar(name) m.charLast = name end
        local function storeActive() if next(m.profiles) then m.profiles[m.active] = true end end

        local function reload()
            wow.fire("PLAYER_LOGOUT")
            storeActive()
            assert.are.same({}, wow.errors, "seed " .. seed .. ": before a reload")
            local clock = _G.time()
            ns = boot(_G.FriendlyForeverDB, clock)
            sentBefore = 0
            -- The login switch: this character's last profile, if it's still there.
            if m.charLast and m.charLast ~= m.active and m.profiles[m.charLast] then
                storeActive()
                m.active, m.undo = m.charLast, nil
            end
            seen.reloads = seen.reloads + 1
        end

        local function pick(list) return list[random.random(#list)] end

        local actions = {
            function()
                local who = pick(GUILD)
                if m.ignored[who] then seen.ignoredOnline = seen.ignoredOnline + 1 end
                online(who)
            end,
            function() buffedBy(pick(STRANGERS), "nameplate" .. random.random(1, 3)) end,
            function() wow.advance(random.random() * 20) end,
            function() wow.advance(random.random(5, 40) * 60) end,
            function() wow.keyDown() end,
            -- Playing on: a few seconds pass, and you press a key.
            function()
                wow.advance(random.random(1, 8))
                wow.keyDown()
            end,
            function()
                local who = pick(EVERYONE)
                slash("ignore " .. DISPLAY[who])
                m.ignored[who] = true
            end,
            -- Someone you'd rather not hear from: ignored while their line waits.
            function()
                local who = pick(GUILD)
                online(who)
                slash("ignore " .. DISPLAY[who])
                m.ignored[who] = true
            end,
            function()
                local who = pick(STRANGERS)
                buffedBy(who, "nameplate" .. random.random(1, 3))
                slash("ignore " .. DISPLAY[who])
                m.ignored[who] = true
            end,
            function()
                local who = pick(EVERYONE)
                slash("unignore " .. DISPLAY[who])
                m.ignored[who] = nil
            end,
            function()
                local minutes = random.random(1, 10)
                slash("snooze " .. minutes)
                m.snoozeUntil = _G.time() + minutes * 60
            end,
            function()
                slash("snooze off")
                m.snoozeUntil = nil
            end,
            function()
                local on = random.random() < 0.75
                slash(on and "on" or "off")
                m.enabled = on
            end,
            function()
                local name = pick(PROFILE_NAMES)
                slash("profile new " .. name)
                if not m.profiles[name] and name ~= m.active then
                    m.profiles[m.active], m.profiles[name] = true, true
                    m.active, m.undo = name, nil
                    rememberChar(name)
                end
            end,
            function()
                local name = pick(PROFILE_NAMES)
                slash("profile use " .. name)
                if name == m.active then
                    rememberChar(name)
                elseif m.profiles[name] then
                    storeActive()
                    m.active, m.undo = name, nil
                    rememberChar(name)
                    seen.switches = seen.switches + 1
                end
            end,
            function()
                local name = pick(PROFILE_NAMES)
                slash("profile delete " .. name)
                if name ~= m.active and m.profiles[name] then
                    m.profiles[name] = nil
                    if m.charLast == name then m.charLast = nil end
                end
            end,
            function()
                slash("export")
                local ignored = {}
                for k in pairs(m.ignored) do ignored[k] = true end
                m.saved = { line = ns.Window.Frame().box:GetText(), ignored = ignored }
                ns.Window.Frame():Hide()
            end,
            function()
                local line = m.saved and random.random() < 0.8 and m.saved.line or "FF1:not a settings line"
                slash("import")
                local window = ns.Window.Frame()
                window.box:SetText(line)
                wow.run(window.accept, "OnClick")
                window:Hide()
                if m.saved and line == m.saved.line then
                    local added = {}
                    for who in pairs(m.saved.ignored) do
                        if not m.ignored[who] then added[who], m.ignored[who] = true, true end
                    end
                    m.undo = { profile = m.active, added = added }
                    seen.imports = seen.imports + 1
                end
            end,
            function()
                slash("import undo")
                if m.undo and m.undo.profile == m.active then
                    for who in pairs(m.undo.added) do m.ignored[who] = nil end
                    m.undo = nil
                    seen.undos = seen.undos + 1
                end
            end,
            function()
                slash("ledger clear")
                thanksSinceClear = 0
            end,
            function() slash(pick({ "ledger", "status", "report", "ignore", "profile" })) end,
            function()
                ns.Options.Open()
                ns.Options.Refresh()
            end,
            reload,
        }

        -- Damage, as another addon or a bad /run would do it.
        local damages = {
            function()
                ns.db.ignore = pick({ 42, "x", true })
                m.ignored = {}
            end,
            function()
                local list = ns.db.ignore
                if type(list) == "table" then list[pick({ 7, "zed-bad", "x" })] = pick({ 42, {}, "Not-Them" }) end
            end,
            function()
                local damage = random.random(1, 4)
                if damage == 1 then
                    ns.db.snoozeUntil = pick({ "x", true, {}, 0 / 0 })
                    m.snoozeUntil = nil
                elseif damage <= 3 then
                    ns.db.snoozeUntil = _G.time() - 5
                    m.snoozeUntil = nil
                else
                    -- Far off: the addon caps it at a day from when it reads it,
                    -- so the model's day (from now) never outlasts the addon's.
                    ns.db.snoozeUntil = pick({ 1e12, math.huge })
                    m.snoozeUntil = _G.time() + ns.Config.SNOOZE_MAX_SECONDS
                end
            end,
            function()
                ns.db.profiles = pick({ 42, "x", { 1, 2 }, { P1 = 5 } })
                m.profiles = {}
            end,
            function()
                ns.db.activeProfile = pick({ 42, true, {}, "" })
                m.active = "Default"
            end,
            function()
                ns.db.charProfiles = pick({ 42, "x", true })
                m.charLast = nil
            end,
            function()
                ns.db.importUndo = pick({ 42, "x", true, { profile = m.active } })
                m.undo = nil
            end,
            function()
                local ledger = ns.db.ledger
                if random.random() < 0.5 then ns.db.ledger = pick({ 42, "x", {} })
                elseif type(ledger) == "table" then ledger[pick({ "entries", "totals", "today" })] = pick({ 42, "x" }) end
            end,
        }

        -- The checks below that the addon agrees with the model read through
        -- code that repairs damage as it reads. So after each damage they wait
        -- a few steps, and what the player does next meets the damage first.
        local unchecked = 0
        for _, damage in ipairs(damages) do
            actions[#actions + 1] = function()
                damage()
                unchecked = random.random(2, 8)
            end
        end

        -- What a player does most: meet people and play on.
        local meet, buffed, playOn = actions[1], actions[2], actions[6]
        for _ = 1, 3 do
            actions[#actions + 1] = meet
            actions[#actions + 1] = buffed
            actions[#actions + 1] = playOn
        end

        for step = 1, steps do
            local at = ("seed %d, step %d"):format(seed, step)
            local snoozedBefore, enabledBefore = snoozed(), m.enabled
            local snoozeEnds = snoozedBefore and m.snoozeUntil
            local ignoredBefore = {}
            for who in pairs(m.ignored) do ignoredBefore[who] = true end
            local which = random.random(#actions)
            actions[which]()
            assert.are.same({}, wow.errors, at .. " (action " .. which .. ")")

            -- What went out this step, read from the simulated client.
            local snoozedNow = snoozed()
            if snoozedBefore and snoozedNow then seen.snoozedSteps = seen.snoozedSteps + 1 end
            for i = sentBefore + 1, #wow.sent do
                local record = wow.sent[i]
                -- When it was sent, by the wall clock (time()) the snooze runs on.
                -- Nothing that changes the snooze moves time, so this is exact.
                local sentAt = wow.state.clock + (record.time - 1000)
                assert.is_false(snoozeEnds and sentAt < snoozeEnds, at .. ": sent while snoozed: " .. record.text)
                assert.is_false(not enabledBefore and not m.enabled, at .. ": sent while off: " .. record.text)
                local kind, first = record.text:match("^(%u%u) (%a+)$")
                local who = first and BY_FIRST[first]
                if who then
                    assert.is_false(ignoredBefore[who] == true and m.ignored[who] == true,
                        at .. ": sent to " .. who .. ", who is ignored: " .. record.text)
                end
                if kind == "GL" then seen.greeted = seen.greeted + 1 end
                if kind == "TY" then
                    seen.thanked = seen.thanked + 1
                    thanksSinceClear = thanksSinceClear + 1
                end
            end
            sentBefore = #wow.sent

            -- The addon agrees with the model.
            assert.are.equal(m.enabled, ns.db.enabled, at .. ": the on/off switch")
            if unchecked > 0 then
                unchecked = unchecked - 1
            else
                local shown = {}
                for who in pairs(m.ignored) do shown[#shown + 1] = DISPLAY[who] end
                table.sort(shown)
                assert.are.same(shown, ns.Ignore.List(), at .. ": the ignore list")
                local names = {}
                for name in pairs(m.profiles) do names[name] = true end
                names[m.active] = true
                assert.are.same(sorted(names), ns.Profiles.List(), at .. ": the profiles")
                assert.are.equal(m.active, ns.Profiles.Active(), at .. ": the active profile")
                assert.are.equal(m.undo ~= nil and m.undo.profile == m.active, ns.Profiles.CanUndoImport(),
                    at .. ": whether there's an import to undo")
                local left = ns.Announcer.SnoozeLeft()
                assert.is_true(left == nil or left <= ns.Config.SNOOZE_MAX_SECONDS, at .. ": snoozed for over a day")
                if snoozedNow then assert.is_truthy(left, at .. ": the snooze ended early") end
                local s = ns.Ledger.Summary()
                assert.is_true(s.stored <= ns.Ledger.MAX_ENTRIES, at .. ": ledger entries")
                assert.is_true(s.thanked <= s.received, at .. ": more thanked than received")
                assert.is_true(s.thanked <= thanksSinceClear,
                    ("%s: the ledger counts %d thanks, %d were said since it was cleared"):format(at, s.thanked,
                        thanksSinceClear))
                assert.is_true(s.todayReceived <= s.received and s.todayThanked <= s.thanked, at .. ": today's counts")
            end
        end
        return seen
    end

    it("survives random storms of commands, reloads and damage, and never sends what it shouldn't", function()
        local total = {}
        for _, seed in ipairs({ 1, 7, 52, 99, 404, 1105, 2026, 31337 }) do
            for key, n in pairs(storm(seed, 600)) do total[key] = (total[key] or 0) + n end
        end
        -- The storms really reached what they test, not just the edges.
        for _, key in ipairs({ "greeted", "thanked", "ignoredOnline", "imports", "undos", "switches", "reloads",
            "snoozedSteps" }) do
            assert.is_true((total[key] or 0) > 0, key .. ": " .. tostring(total[key]))
        end
    end)

    it("replays a seed's storm identically", function()
        local first = storm(29, 200)
        storm(81, 50)
        assert.are.same(first, storm(29, 200))
    end)
end)
