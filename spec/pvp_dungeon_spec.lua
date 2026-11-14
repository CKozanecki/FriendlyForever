-- Spec: #306
-- The owner's rule: inside a dungeon or raid, once every member of your group
-- is in there with you, a member flagged for PvP may be buffed: single buffs,
-- group versions and Greater Blessings. Everywhere else, and while anyone is
-- outside or can't be read, a flagged member is never buffed unless you are
-- flagged too.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local ITEM = wow.ITEM
local INTELLECT, BRILLIANCE = 10157, 23028
local KINGS, GREATER_KINGS = 20217, 25898
local DEADMINES, MOLTEN_CORE = 36, 409

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

describe("Buffing a PvP-flagged member once the whole group is inside (#306)", function()
    local ns, button

    -- A mage who knows Arcane Intellect and Arcane Brilliance and carries
    -- Arcane Powder, in buff mode, in a party of Ann, Bo, Cid and Dot.
    -- opts.known: other spells; opts.class, opts.items; opts.group = false
    -- for no party yet.
    local function boot(opts)
        opts = opts or {}
        ns = wow.boot({ before = function(state)
            state.class = opts.class or "MAGE"
            state.knownSpells = {}
            for _, id in ipairs(opts.known or { INTELLECT, BRILLIANCE }) do state.knownSpells[id] = true end
            state.items = opts.items or { [ITEM.arcanePowder] = 5 }
        end })
        button = ns.BuffButton.Frame()
        slash("buffmode on")
        if opts.group ~= false then
            wow.setGroup("party", { "Ann-Vale", "Bo-Fern", "Cid-Rock", "Dot-Moss" })
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.advance(0)
        end
    end

    local function raid(names)
        wow.setGroup("raid", names)
        wow.fire("GROUP_ROSTER_UPDATE")
        wow.advance(0)
    end

    local function macro() return button:GetAttribute(ns.BuffButton.SECURE_ATTRIBUTE.leftButtonMacroText) end

    -- What the armed button casts, and on whom, after a fresh look.
    local function armed()
        ns.BuffButton.Refresh()
        local text = macro()
        if not text then return nil end
        return text:match("/targetexact ([^\n]+)") .. ": " .. text:match("/cast %[help,nodead%] ([^\n]+)")
    end

    -- Presses until nothing is armed, and returns what was armed each time.
    local function pressThrough()
        local seen = {}
        for _ = 1, 12 do
            local now = armed()
            if not now then break end
            seen[#seen + 1] = now
            wow.pressKey("MOUSEWHEELUP")
        end
        return seen
    end

    -- Whether any cast so far was aimed at this player, or covered them.
    local function reached(id)
        for _, cast in ipairs(wow.casts) do
            if cast.target == id then return true end
            for _, covered in ipairs(cast.covered or {}) do
                if covered == id then return true end
            end
        end
        return false
    end

    local function flag(token) wow.state.units[token].pvp = true end

    -- A battleground with the same four, before its gates open: buff mode
    -- works there as in any raid (after that the addon is quiet, #71).
    local function battleground()
        wow.enterBattleground({ "Ann-Vale", "Bo-Fern", "Cid-Rock", "Dot-Moss" })
        slash("buffmode on")
        assert.is_true(ns.BuffMode.IsOn())
    end

    -- Dot's unit, whichever slot the group gives her.
    local function dot()
        for token, u in pairs(wow.state.units) do
            if u.id == "Dot-Moss" and (token:find("^party%d") or token:find("^raid%d")) then return u end
        end
    end

    describe("in a dungeon or raid with everyone inside (white)", function()
        it("a flagged member gets the single buff like anyone else, in group order", function()
            boot({ known = { INTELLECT } })
            flag("party1")
            wow.enterDungeon(DEADMINES, "The Deadmines")
            assert.are.equal("Ann Vale: Arcane Intellect", armed(), "Ann, flagged, is first as in any group")
            wow.pressKey("MOUSEWHEELUP")
            assert.are.equal(1, #wow.casts)
            assert.are.equal(INTELLECT, wow.casts[1].id)
            assert.are.equal("Ann-Vale", wow.casts[1].target)
            assert.are.equal("Gave Arcane Intellect to Ann Vale.", button.result:GetText())
            assert.are.same({ "Bo Fern: Arcane Intellect", "Cid Rock: Arcane Intellect",
                "Dot Moss: Arcane Intellect" }, pressThrough())
            assert.are.equal("everyone in your group has your buffs", button.subtitle:GetText())
            assert.are.same({}, wow.errors)
        end)

        it("a flagged member is covered by a group version", function()
            boot()
            flag("party4")
            assert.are.equal("Ann Vale: Arcane Intellect", armed(), "out in the world: no group version, as today")
            wow.enterDungeon(DEADMINES, "The Deadmines")
            assert.are.equal("Ann Vale: Arcane Brilliance", armed())
            assert.are.equal("your party (4 missing)", button.title:GetText(), "Dot counts among the missing")
            wow.pressKey("MOUSEWHEELUP")
            assert.are.equal(1, #wow.casts)
            assert.are.equal(BRILLIANCE, wow.casts[1].id)
            assert.are.same({ "Ann-Vale", "Bo-Fern", "Cid-Rock", "Dot-Moss", "Me" }, wow.casts[1].covered)
            assert.is_nil(armed())
            assert.are.equal("everyone in your group has your buffs", button.subtitle:GetText())
            assert.are.same({}, wow.errors)
        end)

        it("in a raid instance, a flagged member is covered by a group version for their subgroup, and gets single buffs", function()
            boot({ group = false })
            raid({ "Ann-Vale", "Bo-Fern", "Cid-Rock", "Dot-Moss", "Eve-Hill" })
            for i = 4, 5 do wow.state.units["raid" .. i].subgroup = 2 end
            flag("raid2")
            flag("raid5")
            wow.enterRaid(MOLTEN_CORE, "Molten Core")
            assert.are.equal("Ann Vale: Arcane Brilliance", armed())
            assert.are.equal("Group 1 (3 missing)", button.title:GetText())
            wow.pressKey("MOUSEWHEELUP")
            assert.is_true(reached("Bo-Fern"), "Bo, flagged, was covered")
            -- Two are left in group 2: one at a time, the flagged Eve included.
            assert.are.same({ "Dot Moss: Arcane Intellect", "Eve Hill: Arcane Intellect" }, pressThrough())
            assert.are.same({}, wow.errors)
        end)

        it("a flagged member is covered by a Greater Blessing", function()
            boot({ class = "PALADIN", known = { KINGS, GREATER_KINGS }, items = { [ITEM.symbolOfKings] = 10 },
                group = false })
            raid({ "Ann-Vale", "Bo-Fern", "Cid-Rock", "Dot-Moss", "Eve-Hill", "Fay-Reed" })
            for i = 1, 6 do wow.state.units["raid" .. i].class = "WARRIOR" end
            flag("raid6")
            assert.are.equal("Ann Vale: Blessing of Kings", armed(), "out in the world: no Greater Blessing, as today")
            wow.enterRaid(MOLTEN_CORE, "Molten Core")
            assert.are.equal("Ann Vale: Greater Blessing of Kings", armed())
            assert.are.equal("Warriors (6 missing)", button.title:GetText())
            wow.pressKey("MOUSEWHEELUP")
            assert.are.equal(GREATER_KINGS, wow.casts[1].id)
            assert.are.same({ "Ann-Vale", "Bo-Fern", "Cid-Rock", "Dot-Moss", "Eve-Hill", "Fay-Reed" },
                wow.casts[1].covered)
            assert.are.same({}, wow.errors)
        end)

        it("it starts when the last member comes in, and stops when one leaves or you do", function()
            boot({ known = { INTELLECT } })
            flag("party4")
            wow.zoneOut("party3")
            wow.enterDungeon(DEADMINES, "The Deadmines")
            assert.are.same({ "Ann Vale: Arcane Intellect", "Bo Fern: Arcane Intellect" }, pressThrough(),
                "Cid is outside: nothing for Dot")
            assert.is_false(reached("Dot-Moss"))
            wow.zoneIn("party3")
            assert.are.equal("Cid Rock: Arcane Intellect", armed(), "everyone is in")
            wow.pressKey("MOUSEWHEELUP")
            assert.are.equal("Dot Moss: Arcane Intellect", armed())
            -- Bo steps out with nothing to tell the addon: Dot waits again.
            wow.zoneOut("party2")
            assert.is_nil(armed())
            wow.zoneIn("party2")
            assert.are.equal("Dot Moss: Arcane Intellect", armed())
            wow.leaveDungeon()
            assert.is_nil(armed(), "out in the world again")
            assert.is_false(reached("Dot-Moss"))
            assert.are.same({}, wow.errors)
        end)

        it("buff mode the dungeon turned on waits for a flagged member like anyone else, then ends as done", function()
            ns = wow.boot({ autoBuffMode = true, before = function(state)
                state.class = "MAGE"
                state.knownSpells = { [INTELLECT] = true }
            end })
            button = ns.BuffButton.Frame()
            -- A group formed out in the world with nobody close by, so
            -- joining turns nothing on.
            wow.setGroup("party", { "Ann-Vale", "Dot-Moss" })
            for _, token in ipairs({ "party1", "party2" }) do wow.zoneOut(token) end
            wow.fire("GROUP_ROSTER_UPDATE")
            assert.is_false(ns.BuffMode.IsOn())
            for _, token in ipairs({ "party1", "party2" }) do wow.zoneIn(token) end
            flag("party2")
            wow.wearBuff("party1", INTELLECT, { source = "player" })
            wow.enterDungeon(DEADMINES, "The Deadmines")
            assert.is_true(ns.BuffMode.IsAuto(), "the dungeon turned it on")
            assert.are.equal("Dot Moss: Arcane Intellect", armed())
            assert.is_true(ns.BuffMode.IsAuto(), "Dot, flagged, still lacks your buff: not done")
            wow.pressKey("MOUSEWHEELUP")
            assert.are.equal("Dot-Moss", wow.casts[1] and wow.casts[1].target)
            ns.BuffButton.Refresh()
            assert.is_false(ns.BuffMode.IsOn())
            local said = false
            for _, line in ipairs(wow.printed) do
                said = said or line:find("everyone is here and has your buffs", 1, true) ~= nil
            end
            assert.is_true(said)
            assert.are.same({}, wow.errors)
        end)

        it("is read again at the press: a member who has left since the button was armed stops it", function()
            for _, known in ipairs({ { INTELLECT }, { INTELLECT, BRILLIANCE } }) do
                local what = #known == 1 and "single" or "group version"
                boot({ known = known })
                flag("party1")
                wow.enterDungeon(DEADMINES, "The Deadmines")
                assert.are.equal(#known == 1 and "Ann Vale: Arcane Intellect" or "Ann Vale: Arcane Brilliance",
                    armed(), what)
                -- Dot leaves the dungeon; no event tells the addon.
                wow.zoneOut("party4")
                wow.pressKey("MOUSEWHEELUP")
                assert.is_false(reached("Ann-Vale"), what .. ": the press re-read it")
                for _, cast in ipairs(wow.casts) do assert.is_nil(cast.covered, what) end
                assert.are.same({}, wow.flaggedBy, what)
                assert.are.same({}, wow.errors, what)
            end
        end)
    end)

    describe("everywhere else, as today (white)", function()
        -- Each sets the scene around a party whose Dot is flagged, and names
        -- who still gets the single buff.
        local elsewhere = {
            { "in the open world", function() end, { "Ann", "Bo", "Cid" } },
            { "in a battleground", battleground, { "Ann", "Bo", "Cid" } },
            { "in an arena", function() wow.enterDungeon(nil, nil, "arena") end, { "Ann", "Bo", "Cid" } },
            { "in a dungeon with one member still outside", function()
                wow.zoneOut("party3")
                wow.enterDungeon(DEADMINES, "The Deadmines")
            end, { "Ann", "Bo" } },
            { "in a dungeon with one member offline", function()
                wow.state.units.party3.offline = true
                wow.enterDungeon(DEADMINES, "The Deadmines")
            end, { "Ann", "Bo" } },
            { "in a raid instance with one member still outside", function()
                wow.zoneOut("party3")
                wow.enterRaid(MOLTEN_CORE, "Molten Core")
            end, { "Ann", "Bo" } },
        }
        local FULL = { Ann = "Ann Vale", Bo = "Bo Fern", Cid = "Cid Rock" }
        for _, case in ipairs(elsewhere) do
            it(case[1] .. ", a flagged member gets nothing: no single buff and no group version", function()
                for _, known in ipairs({ { INTELLECT }, { INTELLECT, BRILLIANCE } }) do
                    local what = #known == 1 and "single" or "group version"
                    boot({ known = known })
                    case[2]()
                    dot().pvp = true
                    local expected = {}
                    for i, first in ipairs(case[3]) do expected[i] = FULL[first] .. ": Arcane Intellect" end
                    assert.are.same(expected, pressThrough(), what)
                    assert.is_false(reached("Dot-Moss"), what)
                    for _, cast in ipairs(wow.casts) do assert.is_nil(cast.covered, what) end
                    assert.are.same({}, wow.flaggedBy, what)
                    assert.is_false(wow.state.pvp == true, what .. ": you aren't flagged")
                    assert.are.same({}, wow.errors, what)
                end
            end)
        end

        it("says why the flagged member is left out", function()
            boot({ known = { INTELLECT } })
            flag("party4")
            pressThrough()
            assert.are.equal("Dot Moss: flagged for PvP and you aren't", button.subtitle:GetText())
            boot()
            flag("party4")
            assert.are.equal("Ann Vale: Arcane Intellect", armed())
            assert.are.equal("Dot Moss is flagged for PvP and you aren't: buffing one at a time",
                button.subtitle:GetText())
        end)

        it("flagged yourself, a flagged member is buffed anywhere, as today", function()
            boot()
            flag("party4")
            wow.state.pvp = true
            assert.are.equal("Ann Vale: Arcane Brilliance", armed())
            wow.pressKey("MOUSEWHEELUP")
            assert.is_true(reached("Dot-Moss"))
            assert.are.same({}, wow.flaggedBy, "already flagged: nothing changed for you")
        end)
    end)

    describe("what can't be read never turns it on (black)", function()
        -- Dot is flagged, everyone is in the Deadmines, and one answer is
        -- missing: Dot must get nothing, singly or from a group version.
        local function nothingForDot(label)
            assert.is_false(reached("Dot-Moss"), label)
            for _, cast in ipairs(wow.casts) do assert.is_nil(cast.covered, label) end
            assert.are.same({}, wow.flaggedBy, label)
            assert.are.same({}, wow.errors, label)
        end

        it("when the game won't say whether you're in a dungeon or raid", function()
            local answers = {
                secret = function() wow.state.inInstanceSecret = true end,
                gone = function() _G.IsInInstance = nil end,
                throws = function() _G.IsInInstance = function() error("blocked") end end,
                ["no kind"] = function() _G.IsInInstance = function() return true end end,
                ["an unknown kind"] = function() _G.IsInInstance = function() return true, "scenario" end end,
                ["a number"] = function() _G.IsInInstance = function() return true, 1 end end,
                ["true for the kind"] = function() _G.IsInInstance = function() return true, true end end,
            }
            for label, setup in pairs(answers) do
                boot()
                flag("party4")
                wow.enterDungeon(DEADMINES, "The Deadmines")
                assert.are.equal("Ann Vale: Arcane Brilliance", armed(), label .. ": readable, the rule holds")
                setup()
                assert.are.same({ "Ann Vale: Arcane Intellect", "Bo Fern: Arcane Intellect",
                    "Cid Rock: Arcane Intellect" }, pressThrough(), label)
                nothingForDot(label)
            end
        end)

        it("when a member can't be read as inside: their connection, whether they're in sight, or their slot", function()
            local function hideSlot(token, answer)
                local real = _G.UnitExists
                _G.UnitExists = function(unit)
                    if unit ~= token then return real(unit) end
                    if answer == "error" then error("blocked") end
                    if answer == "nothing" then return nil end
                    return wow.secret(true)
                end
            end
            -- Each names who still gets the single buff: a member the game
            -- won't show is left out as well.
            local cases = {
                { "Cid's connection is a secret", function() wow.state.units.party3.secrets = { offline = true } end,
                    { "Ann Vale", "Bo Fern", "Cid Rock" } },
                { "whether Cid is in sight is a secret", function() wow.state.units.party3.secrets = { hidden = true } end,
                    { "Ann Vale", "Bo Fern", "Cid Rock" } },
                { "Cid's slot is a secret", function() hideSlot("party3", "secret") end, { "Ann Vale", "Bo Fern" } },
                { "Cid's slot gives no answer", function() hideSlot("party3", "nothing") end, { "Ann Vale", "Bo Fern" } },
                { "Cid's slot errors", function() hideSlot("party3", "error") end, { "Ann Vale", "Bo Fern" } },
                { "every unit is restricted", function() wow.state.unitsRestricted = true end, {} },
            }
            for _, case in ipairs(cases) do
                local label = case[1]
                boot()
                flag("party4")
                wow.enterDungeon(DEADMINES, "The Deadmines")
                assert.are.equal("Ann Vale: Arcane Brilliance", armed(), label .. ": readable, the rule holds")
                case[2]()
                local expected = {}
                for i, name in ipairs(case[3]) do expected[i] = name .. ": Arcane Intellect" end
                assert.are.same(expected, pressThrough(), label)
                nothingForDot(label)
            end
        end)

        it("a member outside whose slot can't be read as you or someone else is still outside", function()
            for _, answer in ipairs({ "secret false", "secret true", "nothing", "error" }) do
                boot()
                flag("party4")
                wow.enterDungeon(DEADMINES, "The Deadmines")
                assert.are.equal("Ann Vale: Arcane Brilliance", armed(), answer .. ": readable, the rule holds")
                -- Cid has left the dungeon, and the game won't say whether
                -- his slot is you: he isn't passed over as if it were.
                wow.zoneOut("party3")
                local real = _G.UnitIsUnit
                _G.UnitIsUnit = function(a, b)
                    if not (a == "party3" and b == "player") then return real(a, b) end
                    if answer == "error" then error("blocked") end
                    if answer == "nothing" then return nil end
                    return wow.secret(answer == "secret true")
                end
                assert.are.same({ "Ann Vale: Arcane Intellect", "Bo Fern: Arcane Intellect" }, pressThrough(), answer)
                nothingForDot(answer)
            end
        end)

        it("when the game won't say whether you're in a raid, nobody is taken to be inside", function()
            local answers = {
                secret = function() _G.IsInRaid = function() return wow.secret(false) end end,
                nothing = function() _G.IsInRaid = function() return nil end end,
                throws = function() _G.IsInRaid = function() error("blocked") end end,
                gone = function() _G.IsInRaid = nil end,
                ["a number"] = function() _G.IsInRaid = function() return 0 end end,
            }
            for label, setup in pairs(answers) do
                boot()
                flag("party4")
                wow.enterDungeon(DEADMINES, "The Deadmines")
                assert.are.equal("Ann Vale: Arcane Brilliance", armed(), label .. ": readable, the rule holds")
                setup()
                assert.are.same({ "Ann Vale: Arcane Intellect", "Bo Fern: Arcane Intellect",
                    "Cid Rock: Arcane Intellect" }, pressThrough(), label)
                nothingForDot(label)
            end
        end)

        it("a slot that can't be read with nobody in it is someone who may be outside", function()
            boot({ group = false })
            wow.setGroup("party", { "Ann-Vale", "Bo-Fern", "Dot-Moss" })
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.advance(0)
            flag("party3")
            wow.enterDungeon(DEADMINES, "The Deadmines")
            assert.are.equal("Ann Vale: Arcane Brilliance", armed())
            local real = _G.UnitExists
            _G.UnitExists = function(unit)
                if unit == "party4" then return wow.secret(false) end
                return real(unit)
            end
            assert.are.same({ "Ann Vale: Arcane Intellect", "Bo Fern: Arcane Intellect" }, pressThrough())
            nothingForDot("party4 unreadable")
        end)

        it("a member whose flag can't be read gets nothing outside the rule, as today", function()
            local scenes = {
                ["in the open world"] = function() end,
                ["in a battleground"] = battleground,
                ["in a dungeon with the instance unreadable"] = function()
                    wow.enterDungeon(DEADMINES, "The Deadmines")
                    wow.state.inInstanceSecret = true
                end,
            }
            for label, scene in pairs(scenes) do
                boot()
                scene()
                dot().secrets = { pvp = true }
                assert.are.same({ "Ann Vale: Arcane Intellect", "Bo Fern: Arcane Intellect",
                    "Cid Rock: Arcane Intellect" }, pressThrough(), label)
                nothingForDot(label)
                assert.are.equal("Dot Moss: can't see whether they're flagged for PvP", button.subtitle:GetText(), label)
            end
        end)

        it("your own flag that can't be read isn't 'flagged too'", function()
            boot()
            flag("party4")
            local real = _G.UnitIsPVP
            _G.UnitIsPVP = function(unit)
                if unit == "player" then return wow.secret(true) end
                return real(unit)
            end
            assert.are.same({ "Ann Vale: Arcane Intellect", "Bo Fern: Arcane Intellect",
                "Cid Rock: Arcane Intellect" }, pressThrough())
            nothingForDot("your flag is a secret")
        end)

        it("inside with everyone in, a member whose flag can't be read is buffed like a flagged one", function()
            boot()
            wow.state.units.party4.secrets = { pvp = true }
            wow.enterDungeon(DEADMINES, "The Deadmines")
            assert.are.equal("Ann Vale: Arcane Brilliance", armed())
            assert.are.equal("your party (4 missing)", button.title:GetText())
            wow.pressKey("MOUSEWHEELUP")
            assert.is_true(reached("Dot-Moss"))
            assert.are.same({}, wow.errors)
        end)

        it("a group version asked for without saying flagged members may be covered never covers one", function()
            boot()
            flag("party4")
            wow.enterDungeon(DEADMINES, "The Deadmines")
            local buff
            for _, b in ipairs(ns.BuffData.Offerable()) do
                if b.groupCast then buff = b end
            end
            local members = {}
            for i, name in ipairs({ "Ann-Vale", "Bo-Fern", "Cid-Rock", "Dot-Moss" }) do
                members[i] = { unit = "party" .. i, name = name, class = "MAGE" }
            end
            local function offer(flaggedOk)
                return ns.GroupCasts.Offer(buff, members, { units = { "party1", "party2", "party3", "party4" },
                    inRaid = false, Needs = function() return true end, InRange = function() return true end,
                    flaggedOk = flaggedOk })
            end
            local got = offer(true)
            assert.are.equal("Arcane Brilliance", got and got.spell, "said so: covered")
            -- Left out, or anything but true: Dot's flag stops it.
            for _, value in ipairs({ "nil", false, "yes", 1 }) do
                local label = tostring(value)
                if value == "nil" then value = nil end
                local none, why = offer(value)
                assert.is_nil(none, label)
                assert.are.equal("Dot Moss is flagged for PvP and you aren't: buffing one at a time", why, label)
            end
            assert.are.same({}, wow.errors)
        end)

        it("nothing casts without a press", function()
            boot()
            flag("party4")
            wow.enterDungeon(DEADMINES, "The Deadmines")
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.advance(120)
            ns.BuffButton.Refresh()
            assert.are.equal("Ann Vale: Arcane Brilliance", armed())
            assert.are.equal(0, #wow.casts)
            assert.are.same({}, wow.flaggedBy)
        end)
    end)

    describe("chaos (red)", function()
        -- Where a flagged member must get nothing, and where the rule holds.
        local OUTSIDE = { "the open world", "an arena", "a battleground", "a dungeon, one outside",
            "a dungeon, one offline", "a raid, one outside", "a dungeon the game won't name",
            "a dungeon, a slot unreadable", "a dungeon, a connection unreadable", "a dungeon, sight unreadable",
            "the open world, your flag unreadable", "the open world, their flag unreadable" }
        local INSIDE = { "a dungeon", "a raid" }

        it("a storm of joins, leaves and zone changes never offers a buff to a flagged member outside the rule", function()
            local POOL = { "Ann-Vale", "Bo-Fern", "Cid-Rock", "Dot-Moss", "Eve-Hill", "Fay-Reed", "Gus-Lane", "Hal-Pine" }
            local kinds = {}
            for _, kind in ipairs(OUTSIDE) do kinds[#kinds + 1] = kind end
            for _, kind in ipairs(INSIDE) do kinds[#kinds + 1] = kind end
            local total = { single = 0, group = 0, casts = 0 }
            for _, seed in ipairs({ 5, 23, 88, 431, 2027, 9002 }) do
                random.seed(seed)
                for _ = 1, 5 do random.random() end
                boot({ group = false, items = { [ITEM.arcanePowder] = 1000 } })
                -- The one slot whose existence the game won't give, or nil.
                local hiddenSlot
                local realExists = _G.UnitExists
                _G.UnitExists = function(unit)
                    if unit == hiddenSlot then return wow.secret(true) end
                    return realExists(unit)
                end
                -- Whether the game won't give your own PvP flag.
                local myFlagHidden = false
                local realFlag = _G.UnitIsPVP
                _G.UnitIsPVP = function(unit)
                    if unit == "player" and myFlagHidden then return wow.secret(true) end
                    return realFlag(unit)
                end
                local per = { single = 0, group = 0, refused = {} }
                local flaggedSeen = 0 -- how many times a buff has flagged you so far

                -- The other group members' slots, in slot order.
                local function others()
                    local out = {}
                    for token, u in pairs(wow.state.units) do
                        if (token:find("^party%d") or token:find("^raid%d")) and u ~= wow.state.units.player then
                            out[#out + 1] = token
                        end
                    end
                    table.sort(out, function(a, b) return tonumber(a:match("%d+")) < tonumber(b:match("%d+")) end)
                    return out
                end

                -- The owner's rule, from the simulated client's own state: in
                -- a dungeon or raid the game names, with every other member
                -- connected, in sight and readable.
                local function ruleHolds()
                    local state = wow.state
                    if not state.inInstance or state.inInstanceSecret or state.unitsRestricted or hiddenSlot then
                        return false
                    end
                    local kind = state.instanceType or "party"
                    if kind ~= "party" and kind ~= "raid" then return false end
                    for _, token in ipairs(others()) do
                        local u = state.units[token]
                        if u.offline or u.hidden then return false end
                        if u.secrets and (u.secrets.offline or u.secrets.hidden) then return false end
                    end
                    return true
                end

                -- How things stand before a press, from the client's state.
                local function snapshot()
                    local now = { rule = ruleHolds(), iAmFlagged = wow.state.pvp == true, members = {} }
                    for _, token in ipairs(others()) do
                        local u = wow.state.units[token]
                        now.members[u.id] = { pvp = u.pvp == true,
                            secretPvp = u.secrets ~= nil and u.secrets.pvp == true }
                    end
                    return now
                end

                -- The invariant, for every cast since `from` (refused ones
                -- too: the button offered them): nobody flagged, or whose flag
                -- couldn't be read, was aimed at or covered unless you were
                -- flagged too or the rule held. And a buff flagged you only
                -- where the rule held.
                local function check(step, from, was)
                    for i = from + 1, #wow.casts do
                        local cast = wow.casts[i]
                        total.casts = total.casts + 1
                        local ids = { cast.target }
                        for _, id in ipairs(cast.covered or {}) do ids[#ids + 1] = id end
                        for _, id in ipairs(ids) do
                            local m = was.members[id]
                            if m and (m.pvp or m.secretPvp) then
                                assert.is_true(was.iAmFlagged or was.rule, ("seed %d, step %s: %s reached %s, %s, outside the rule")
                                    :format(seed, step, cast.spell, id, m.pvp and "flagged" or "whose flag can't be read"))
                                if m.pvp and not was.iAmFlagged and not cast.failed then
                                    local how = cast.covered and "group" or "single"
                                    per[how], total[how] = per[how] + 1, total[how] + 1
                                end
                            end
                        end
                    end
                    if #wow.flaggedBy > flaggedSeen then
                        assert.is_true(was.rule, ("seed %d, step %s: a buff flagged you outside the rule"):format(seed, step))
                        flaggedSeen = #wow.flaggedBy
                    end
                end

                local function press(step)
                    local was, from = snapshot(), #wow.casts
                    wow.pressKey("MOUSEWHEELUP")
                    check(step, from, was)
                    return #wow.casts > from
                end

                local function anyone()
                    local list = others()
                    return list[random.random(math.max(#list, 1))]
                end
                local function member(fn)
                    return function()
                        local token = anyone()
                        if token then fn(wow.state.units[token], token) end
                    end
                end
                local function roster()
                    hiddenSlot = nil
                    local names = {}
                    for _, name in ipairs(POOL) do
                        if random.random() < 0.6 then names[#names + 1] = name end
                    end
                    local kind = random.random(2) == 1 and "party" or "raid"
                    if kind == "party" then while #names > 4 do table.remove(names) end end
                    wow.setGroup(kind, names)
                    for _, token in ipairs(others()) do
                        local u = wow.state.units[token]
                        u.pvp = random.random() < 0.4
                        u.subgroup = random.random(2)
                        if random.random() < 0.2 then wow.zoneOut(token) end
                    end
                    wow.fire("GROUP_ROSTER_UPDATE")
                end
                local actions = {
                    roster, roster,
                    function() wow.leaveDungeon() end,
                    function() wow.enterDungeon(DEADMINES, "The Deadmines") end,
                    function() wow.enterDungeon(DEADMINES, "The Deadmines") end,
                    function() wow.enterRaid(MOLTEN_CORE, "Molten Core") end,
                    function() wow.enterDungeon(nil, nil, "arena") end,
                    member(function(_, token) wow.zoneOut(token) end),
                    member(function(_, token) wow.zoneIn(token) end),
                    member(function(_, token) wow.zoneIn(token) end),
                    member(function(u) u.offline = random.random() < 0.3 end),
                    member(function(u) u.offline = false end),
                    member(function(u) u.pvp = random.random() < 0.5 end),
                    member(function(u) u.pvp = true end),
                    member(function(u) u.dead = random.random() < 0.2 end),
                    member(function(u)
                        u.secrets = random.random() < 0.3 and ({ { pvp = true }, { hidden = true },
                            { offline = true } })[random.random(3)] or nil
                    end),
                    member(function(u) u.auras, u.auraSources, u.auraDurations, u.auraExpires = nil, nil, nil, nil end),
                    member(function(u) u.auras, u.auraSources, u.auraDurations, u.auraExpires = nil, nil, nil, nil end),
                    function() wow.state.pvp = false end,
                    function() wow.state.pvp = false end,
                    function() wow.state.pvp = random.random() < 0.2 end,
                    function() wow.state.inInstanceSecret = random.random() < 0.2 end,
                    function() wow.state.unitsRestricted = random.random() < 0.1 end,
                    function() hiddenSlot = random.random() < 0.3 and anyone() or nil end,
                    function() myFlagHidden = random.random() < 0.2 end,
                    function() ns.db.buffBack.groupVersions = random.random() < 0.7 end,
                    function() if wow.state.inCombat then wow.leaveCombat() else wow.enterCombat() end end,
                    function() if wow.state.inCombat then wow.leaveCombat() end end,
                    function() slash("buffmode on") end,
                    function() wow.advance(random.random() * 20) end,
                    function() wow.fire("GROUP_ROSTER_UPDATE") end,
                }

                -- A staged scene: four members the storm has never met (the
                -- addon remembers what it just gave by name), one of them
                -- flagged, and you not. Outside the rule, pressing until the
                -- button is empty must never reach the flagged one; it counts
                -- as reached when the presses did buff someone else. Inside
                -- it, the casts that reach the flagged one are counted.
                local staged = 0
                local function stage(step, kind)
                    staged = staged + 1
                    hiddenSlot, myFlagHidden = nil, false
                    if wow.state.inCombat then wow.leaveCombat() end
                    wow.state.inInstanceSecret, wow.state.unitsRestricted, wow.state.pvp = false, false, false
                    wow.leaveDungeon()
                    local tag = string.char(64 + math.ceil(staged / 26), 97 + (staged - 1) % 26)
                    local names = { "Kit-" .. tag, "Lee-" .. tag, "Mo-" .. tag, "Nan-" .. tag }
                    if kind == "a battleground" then
                        wow.enterBattleground(names) -- before the gates open
                    else
                        wow.setGroup(kind:find("raid") and "raid" or "party", names)
                        wow.fire("GROUP_ROSTER_UPDATE")
                    end
                    slash("buffmode on")
                    ns.db.buffBack.groupVersions = random.random() < 0.5
                    local list = others()
                    local at = random.random(#list)
                    local flagged = wow.state.units[list[at]]
                    local other = list[at % #list + 1]
                    flagged.pvp = true
                    if kind == "an arena" then
                        wow.enterDungeon(nil, nil, "arena")
                    elseif kind == "a dungeon, one outside" or kind == "a raid, one outside" then
                        wow.zoneOut(other)
                    elseif kind == "a dungeon, one offline" then
                        wow.state.units[other].offline = true
                    elseif kind == "a dungeon, a connection unreadable" then
                        wow.state.units[other].secrets = { offline = true }
                    elseif kind == "a dungeon, sight unreadable" then
                        wow.state.units[other].secrets = { hidden = true }
                    end
                    if kind:find("^a dungeon") then wow.enterDungeon(DEADMINES, "The Deadmines") end
                    if kind:find("^a raid") then wow.enterRaid(MOLTEN_CORE, "Molten Core") end
                    if kind == "a dungeon the game won't name" then wow.state.inInstanceSecret = true end
                    if kind == "a dungeon, a slot unreadable" then hiddenSlot = other end
                    if kind == "the open world, your flag unreadable" then myFlagHidden = true end
                    if kind == "the open world, their flag unreadable" then flagged.secrets = { pvp = true } end
                    local buffed = 0
                    for _ = 1, 8 do
                        if not press(step .. " (" .. kind .. ")") then break end
                        buffed = buffed + 1
                    end
                    if buffed > 0 and buffed < 8 and not ruleHolds() then
                        per.refused[kind] = (per.refused[kind] or 0) + 1
                    end
                    if kind == "a battleground" then wow.leaveBattleground() end
                end

                for step = 1, 560 do
                    if step % 10 == 0 then
                        stage(step, kinds[step / 10 % #kinds + 1])
                    else
                        local was, from = snapshot(), #wow.casts
                        actions[random.random(#actions)]()
                        check(step, from, was)
                        press(step)
                    end
                end
                assert.are.same({}, wow.errors, "seed " .. seed)
                for _, kind in ipairs(OUTSIDE) do
                    assert.is_true((per.refused[kind] or 0) >= 3, ("seed %d left a flagged member out in %s %d times")
                        :format(seed, kind, per.refused[kind] or 0))
                end
                assert.is_true(per.single >= 2, ("seed %d: %d single buffs to a flagged member inside"):format(seed, per.single))
                assert.is_true(per.group >= 2, ("seed %d: %d group casts over a flagged member inside"):format(seed, per.group))
            end
            assert.is_true(total.casts > 500, "casts: " .. total.casts)
        end)
    end)
end)
