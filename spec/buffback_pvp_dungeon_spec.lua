-- Spec: #316, #335
-- The owner's rule (#306) for buff back: a favour owed to a member of your
-- group who is flagged for PvP is offered when you're inside a dungeon or
-- raid and every member of the group is in there with you. A flagged player
-- outside your group is refused everywhere. Everywhere else, and while
-- anyone is outside or can't be read, a flagged player is refused unless
-- you're flagged too, as before.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local MOTW, MOTW_1, INTELLECT = 9885, 1126, 10157
local DEADMINES, MOLTEN_CORE = 36, 409
local FLAGGED = "Bob Stone: they're flagged for PvP and you aren't"
local UNSEEN = "Bob Stone: can't see whether they're flagged for PvP (target them, or show friendly nameplates)"

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

describe("Buff back to a PvP-flagged group member once the whole group is inside (#316)", function()
    local ns, button

    -- A druid who knows Mark of the Wild.
    local function boot()
        ns = wow.boot({ before = function(state)
            state.class = "DRUID"
            state.knownSpells = { [MOTW_1] = true, [MOTW] = true }
        end })
        ns.db.buff.messages = { "Thanks {name}" }
        button = ns.BuffButton.Frame()
    end

    local function macro() return button:GetAttribute(ns.BuffButton.SECURE_ATTRIBUTE.leftButtonMacroText) end

    -- A player the game shows under token (a nameplate, your target).
    local function show(token, full, spec)
        spec = spec or {}
        spec.name, spec.surname = full:match("^([^%-]+)%-(.+)$")
        spec.id, spec.class = full, spec.class or "WARRIOR"
        wow.addUnit(token, spec)
    end

    -- They buff you while outside your group: you owe them one.
    local function owe(token)
        wow.loseBuff(INTELLECT)
        wow.gainBuff({ sourceUnit = token, name = "Arcane Intellect", spellId = INTELLECT })
    end

    -- Every unit the game has for this player (their nameplate and their
    -- group slot are one player): flagged or not.
    local function flag(id, value)
        for _, u in pairs(wow.state.units) do
            if u.id == id then u.pvp = value end
        end
    end

    local function party(names)
        wow.setGroup("party", names)
        wow.fire("GROUP_ROSTER_UPDATE")
        wow.advance(0)
    end

    -- Bob Stone, on a nameplate, buffed you while a stranger, then joined
    -- your party with Ann, Cid and Dot, and is flagged for PvP. You aren't.
    -- Slots: Bob party1, Ann party2, Cid party3, Dot party4.
    local function bobOwedInParty()
        boot()
        show("nameplate1", "Bob-Stone")
        owe("nameplate1")
        assert.are.equal(1, ns.Offers.Count())
        party({ "Bob-Stone", "Ann-Vale", "Cid-Rock", "Dot-Moss" })
        flag("Bob-Stone", true)
        assert.is_true(ns.Greeter.IsInMyGroup("Bob-Stone"))
    end

    -- What buff back offers now, as "Name: Spell", or its reason.
    local function offered()
        local offer, why = ns.Offers.Current()
        if offer then return ns.Util.DisplayName(offer.name) .. ": " .. offer.spell end
        return why
    end

    -- Bob got nothing, and nothing flagged you.
    local function nothingForBob(label)
        wow.press(button)
        for _, cast in ipairs(wow.casts) do assert.are_not.equal("Bob-Stone", cast.target, label) end
        assert.are.equal(1, ns.Offers.Count(), label .. ": still owed")
        assert.are.same({}, wow.flaggedBy, label)
        assert.is_false(wow.state.pvp == true, label .. ": you aren't flagged")
        assert.are.same({}, wow.errors, label)
    end

    describe("in a dungeon or raid with everyone inside (white)", function()
        it("a favour owed to a flagged group member is offered, and a press returns it", function()
            bobOwedInParty()
            assert.are.equal(FLAGGED, offered(), "out in the world: refused, as today")
            wow.enterDungeon(DEADMINES, "The Deadmines")
            assert.are.equal("Bob Stone: Mark of the Wild", offered())
            assert.is_truthy(macro())
            wow.press(button)
            assert.are.equal(1, #wow.casts)
            assert.are.equal(MOTW, wow.casts[1].id)
            assert.are.equal("Bob-Stone", wow.casts[1].target)
            assert.are.equal(0, ns.Offers.Count(), "returned")
            assert.are.same({ "Bob-Stone" }, wow.flaggedBy, "the game flags you, which is safe in here")
            assert.are.same({}, wow.errors)
        end)

        it("in a raid instance, with the raid all inside", function()
            boot()
            show("nameplate1", "Bob-Stone")
            owe("nameplate1")
            wow.setGroup("raid", { "Ann-Vale", "Cid-Rock", "Dot-Moss", "Eve-Hill", "Bob-Stone", "Fay-Reed" })
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.advance(0)
            flag("Bob-Stone", true)
            assert.are.equal(FLAGGED, offered())
            wow.enterRaid(MOLTEN_CORE, "Molten Core")
            assert.are.equal("Bob Stone: Mark of the Wild", offered())
            wow.press(button)
            assert.are.equal("Bob-Stone", wow.casts[1] and wow.casts[1].target)
            assert.are.equal(0, ns.Offers.Count())
            assert.are.same({}, wow.errors)
        end)

        it("starts once the last member comes in, and is read again at the press", function()
            bobOwedInParty()
            wow.zoneOut("party4")
            wow.enterDungeon(DEADMINES, "The Deadmines")
            assert.are.equal(FLAGGED, offered(), "Dot is still outside")
            assert.is_nil(macro())
            wow.zoneIn("party4")
            ns.BuffButton.Refresh()
            assert.are.equal("Bob Stone: Mark of the Wild", offered())
            assert.is_truthy(macro())
            -- Armed, then Dot steps out before the press: the press reads
            -- the rule again and casts nothing.
            wow.zoneOut("party4")
            nothingForBob("Dot left before the press")
            assert.are.equal(0, #wow.casts)
        end)

        it("in buff mode, the favour comes first and is returned like any other", function()
            bobOwedInParty()
            slash("buffmode on")
            wow.enterDungeon(DEADMINES, "The Deadmines")
            ns.BuffButton.Refresh()
            assert.are.equal("Bob Stone: Mark of the Wild", offered())
            wow.pressKey("MOUSEWHEELUP")
            assert.are.equal("Bob-Stone", wow.casts[1] and wow.casts[1].target)
            assert.are.equal(0, ns.Offers.Count(), "the favour, not a group buff, was returned")
            assert.are.same({}, wow.errors)
        end)

        it("a group member whose flag can't be read is offered there like a flagged one, as buff mode does", function()
            bobOwedInParty()
            for _, u in pairs(wow.state.units) do
                if u.id == "Bob-Stone" then u.pvp, u.secrets = false, { pvp = true } end
            end
            assert.are.equal(UNSEEN, offered(), "out in the world: refused, as today")
            wow.enterDungeon(DEADMINES, "The Deadmines")
            assert.are.equal("Bob Stone: Mark of the Wild", offered())
            wow.press(button)
            assert.are.equal("Bob-Stone", wow.casts[1] and wow.casts[1].target)
            assert.are.same({}, wow.errors)
        end)
    end)

    describe("everywhere else, as today (white)", function()
        local scenes = {
            { "in the open world", function() end },
            { "in a city", function() wow.setMap(wow.CAPITAL.stormwind) end },
            { "in an arena", function() wow.enterDungeon(nil, nil, "arena") end },
            { "in a dungeon with one member still outside", function()
                wow.zoneOut("party3")
                wow.enterDungeon(DEADMINES, "The Deadmines")
            end },
            { "in a dungeon with one member offline", function()
                wow.state.units.party3.offline = true
                wow.enterDungeon(DEADMINES, "The Deadmines")
            end },
            { "in a raid instance with one member still outside", function()
                wow.zoneOut("party4")
                wow.enterRaid(MOLTEN_CORE, "Molten Core")
            end },
        }
        for _, scene in ipairs(scenes) do
            it(scene[1] .. ", a favour owed to a flagged group member is refused with today's reason", function()
                bobOwedInParty()
                scene[2]()
                ns.BuffButton.Refresh()
                assert.are.equal(FLAGGED, offered(), scene[1])
                assert.is_nil(macro(), scene[1])
                nothingForBob(scene[1])
                assert.are.equal(0, #wow.casts, scene[1])
            end)
        end

        it("in a battleground before its gates open, a favour owed to a flagged member is refused", function()
            boot()
            show("nameplate1", "Bob-Stone")
            owe("nameplate1")
            wow.enterBattleground({ "Bob-Stone", "Ann-Vale", "Cid-Rock", "Dot-Moss" })
            flag("Bob-Stone", true)
            assert.are.equal(FLAGGED, offered())
            nothingForBob("battleground")
            assert.are.equal(0, #wow.casts)
        end)

        it("flagged yourself, the favour is returned anywhere, as today", function()
            bobOwedInParty()
            wow.state.pvp = true
            assert.are.equal("Bob Stone: Mark of the Wild", offered())
            wow.press(button)
            assert.are.equal("Bob-Stone", wow.casts[1] and wow.casts[1].target)
            assert.are.same({}, wow.flaggedBy, "already flagged: nothing changed for you")
        end)

        it("an unflagged group member's favour is returned anywhere, as today", function()
            bobOwedInParty()
            flag("Bob-Stone", false)
            assert.are.equal("Bob Stone: Mark of the Wild", offered())
            wow.press(button)
            assert.are.equal("Bob-Stone", wow.casts[1] and wow.casts[1].target)
            assert.are.same({}, wow.flaggedBy)
        end)
    end)

    describe("what can't be read never offers it (black)", function()
        -- Bob is owed, flagged and in the party, everyone is in the
        -- Deadmines, and setup() takes one answer away.
        local function refusedInside(label, setup, why)
            bobOwedInParty()
            wow.enterDungeon(DEADMINES, "The Deadmines")
            assert.are.equal("Bob Stone: Mark of the Wild", offered(), label .. ": readable, it's offered")
            setup()
            assert.are.equal(why or FLAGGED, offered(), label)
            nothingForBob(label)
            assert.are.equal(0, #wow.casts, label)
        end

        it("when the game won't say whether you're in a dungeon or raid", function()
            local answers = {
                secret = function() wow.state.inInstanceSecret = true end,
                gone = function() _G.IsInInstance = nil end,
                throws = function() _G.IsInInstance = function() error("blocked") end end,
                ["no kind"] = function() _G.IsInInstance = function() return true end end,
                ["an unknown kind"] = function() _G.IsInInstance = function() return true, "scenario" end end,
                ["a number"] = function() _G.IsInInstance = function() return true, 1 end end,
            }
            for label, setup in pairs(answers) do refusedInside(label, setup) end
        end)

        it("when the game won't say whether you're in a raid", function()
            local answers = {
                secret = function() _G.IsInRaid = function() return wow.secret(false) end end,
                nothing = function() _G.IsInRaid = function() return nil end end,
                throws = function() _G.IsInRaid = function() error("blocked") end end,
                gone = function() _G.IsInRaid = nil end,
            }
            for label, setup in pairs(answers) do refusedInside(label, setup) end
        end)

        it("when another member can't be read as inside: their connection, sight or slot", function()
            local function hideSlot(token, answer)
                local real = _G.UnitExists
                _G.UnitExists = function(unit)
                    if unit ~= token then return real(unit) end
                    if answer == "error" then error("blocked") end
                    if answer == "nothing" then return nil end
                    return wow.secret(true)
                end
            end
            local cases = {
                { "Cid's connection is a secret", function() wow.state.units.party3.secrets = { offline = true } end },
                { "whether Cid is in sight is a secret", function() wow.state.units.party3.secrets = { hidden = true } end },
                { "Cid's slot is a secret", function() hideSlot("party3", "secret") end },
                { "Cid's slot gives no answer", function() hideSlot("party3", "nothing") end },
                { "Cid's slot errors", function() hideSlot("party3", "error") end },
            }
            for _, case in ipairs(cases) do refusedInside(case[1], case[2]) end
        end)

        it("when Bob's own slot can't be read as him: his name there is a secret or missing", function()
            for _, answer in ipairs({ "secret", "nothing" }) do
                refusedInside(answer, function()
                    local real = _G.UnitName
                    _G.UnitName = function(unit)
                        if unit ~= "party1" then return real(unit) end
                        if answer == "nothing" then return nil end
                        return wow.secret("Bob"), wow.secret("Stone")
                    end
                end)
            end
        end)

        it("when Bob's own slot can't be read as holding someone", function()
            refusedInside("Bob's slot is a secret", function()
                local real = _G.UnitExists
                _G.UnitExists = function(unit)
                    if unit == "party1" then return wow.secret(true) end
                    return real(unit)
                end
            end)
        end)

        it("Bob's flag that can't be read is refused outside the rule, as today", function()
            local scenes = {
                ["in the open world"] = function() end,
                ["in a dungeon the game won't name"] = function()
                    wow.enterDungeon(DEADMINES, "The Deadmines")
                    wow.state.inInstanceSecret = true
                end,
                ["in a dungeon with one member outside"] = function()
                    wow.zoneOut("party3")
                    wow.enterDungeon(DEADMINES, "The Deadmines")
                end,
            }
            for label, scene in pairs(scenes) do
                bobOwedInParty()
                for _, u in pairs(wow.state.units) do
                    if u.id == "Bob-Stone" then u.secrets = { pvp = true } end
                end
                scene()
                assert.are.equal(UNSEEN, offered(), label)
                nothingForBob(label)
                assert.are.equal(0, #wow.casts, label)
            end
        end)

        it("your own flag that can't be read isn't 'flagged too'", function()
            bobOwedInParty()
            local real = _G.UnitIsPVP
            _G.UnitIsPVP = function(unit)
                if unit == "player" then return wow.secret(true) end
                return real(unit)
            end
            assert.are.equal(FLAGGED, offered())
            nothingForBob("your flag is a secret")
            assert.are.equal(0, #wow.casts)
        end)

        it("a flagged player who isn't in your group is never offered it, everyone inside or not", function()
            boot()
            show("nameplate1", "Bob-Stone")
            owe("nameplate1")
            -- A party without Bob, one with his first name included.
            party({ "Bob-Fern", "Ann-Vale", "Cid-Rock", "Dot-Moss" })
            flag("Bob-Stone", true)
            assert.is_false(ns.Greeter.IsInMyGroup("Bob-Stone"))
            for _, where in ipairs({ "open world", "dungeon", "raid" }) do
                if where == "dungeon" then wow.enterDungeon(DEADMINES, "The Deadmines") end
                if where == "raid" then wow.enterRaid(MOLTEN_CORE, "Molten Core") end
                assert.are.equal(FLAGGED, offered(), where)
                nothingForBob(where)
            end
            -- And with no group at all, in a dungeon.
            party({})
            wow.enterDungeon(DEADMINES, "The Deadmines")
            assert.are.equal(FLAGGED, offered(), "no group")
            nothingForBob("no group")
            assert.are.equal(0, #wow.casts)
        end)

        it("nothing casts without a press", function()
            bobOwedInParty()
            wow.enterDungeon(DEADMINES, "The Deadmines")
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.advance(60)
            ns.BuffButton.Refresh()
            assert.is_truthy(macro())
            assert.are.equal(0, #wow.casts)
            assert.are.same({}, wow.flaggedBy)
        end)
    end)

    describe("chaos (red)", function()
        -- Where a favour owed to a flagged player must be refused, and where
        -- the rule holds for a member of your group.
        local OUTSIDE = { "the open world", "an arena", "a battleground", "a dungeon, one outside",
            "a dungeon, one offline", "a raid, one outside", "a dungeon the game won't name",
            "a dungeon, a slot unreadable", "a dungeon, a connection unreadable", "a dungeon, sight unreadable",
            "the open world, your flag unreadable", "the open world, their flag unreadable",
            "a dungeon, not in your group", "a dungeon, their name in the group unreadable",
            "a dungeon, one outside, IsInRaid lying", "a raid, one outside, IsInRaid lying" }
        local INSIDE = { "a dungeon", "a raid", "a dungeon, their flag unreadable" }

        it("a storm of favours, joins, leaves and zone changes never offers a favour to a flagged player outside the rule", function()
            local POOL = { "Ann-Vale", "Bo-Fern", "Cid-Rock", "Dot-Moss", "Eve-Hill", "Fay-Reed", "Gus-Lane", "Hal-Pine" }
            local kinds = {}
            for _, kind in ipairs(OUTSIDE) do kinds[#kinds + 1] = kind end
            for _, kind in ipairs(INSIDE) do kinds[#kinds + 1] = kind end
            local total = { returned = 0, casts = 0 }
            for _, seed in ipairs({ 7, 31, 104, 577, 2026, 8191 }) do
                random.seed(seed)
                for _ = 1, 5 do random.random() end
                boot()
                -- Nothing from the hidden channel: its send queue can wait a
                -- rounding error's worth, which the simulated clock can't
                -- step past (#325). The rule here sends nothing.
                ns.Comm.Send = function() return false, "not in this storm" end
                -- Each player's PvP flag, on every unit that is them: { pvp, secret }.
                local flags = {}
                -- The one slot whose existence, or whose name, the game won't give, or nil.
                local hiddenSlot, hiddenName
                local realExists, realName = _G.UnitExists, _G.UnitName
                _G.UnitExists = function(unit)
                    if unit == hiddenSlot then return wow.secret(true) end
                    return realExists(unit)
                end
                _G.UnitName = function(unit)
                    if unit == hiddenName then return wow.secret("Hidden"), wow.secret("Name") end
                    return realName(unit)
                end
                -- Whether the game won't give your own PvP flag.
                local myFlagHidden = false
                local realFlag = _G.UnitIsPVP
                _G.UnitIsPVP = function(unit)
                    if unit == "player" and myFlagHidden then return wow.secret(true) end
                    return realFlag(unit)
                end
                -- Whether IsInRaid() sometimes lies (#335): while set, each
                -- call flips the true answer half the time, from a generator
                -- of its own so the storm's own sequence isn't moved.
                local raidLies, lieState = false, seed
                local realRaid = _G.IsInRaid
                _G.IsInRaid = function()
                    local truth = realRaid()
                    if not raidLies then return truth end
                    lieState = (lieState * 48271) % 2147483647
                    if lieState % 2 == 0 then return not truth end
                    return truth
                end
                local per = { returned = 0, refused = {}, scenes = {}, insideScenes = 0, storm = 0 }
                local staging = false -- inside a staged scene
                local flaggedSeen = 0 -- how many times a buff has flagged you so far

                -- Every unit of a player carries their flag.
                local function sync()
                    for _, u in pairs(wow.state.units) do
                        local f = u.id and flags[u.id]
                        if f and u ~= wow.state.units.player then
                            u.pvp = f.pvp
                            if f.secret then
                                u.secrets = u.secrets or {}
                                u.secrets.pvp = true
                            elseif u.secrets then
                                u.secrets.pvp = nil
                            end
                        end
                    end
                end

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

                -- How things stand before a press, from the client's state:
                -- who is flagged (or can't be read), and who is in your group.
                local function snapshot()
                    local now = { rule = ruleHolds(), iAmFlagged = wow.state.pvp == true, flagged = {}, member = {},
                        buffMode = ns.BuffMode.IsOn() }
                    for id, f in pairs(flags) do now.flagged[id] = f.pvp or f.secret end
                    for id in pairs(wow.state.groupMembers or {}) do now.member[id] = true end
                    return now
                end

                -- The invariant, for every cast since `from` (refused ones
                -- too: the button offered them): nobody flagged, or whose flag
                -- couldn't be read, was aimed at or covered unless you were
                -- flagged too, or the rule held and they were in your group.
                -- And a buff flagged you only where the rule held.
                local function check(step, from, was)
                    for i = from + 1, #wow.casts do
                        local cast = wow.casts[i]
                        total.casts = total.casts + 1
                        local ids = { cast.target }
                        for _, id in ipairs(cast.covered or {}) do ids[#ids + 1] = id end
                        for _, id in ipairs(ids) do
                            if was.flagged[id] then
                                assert.is_true(was.iAmFlagged or (was.rule and was.member[id]),
                                    ("seed %d, step %s: %s reached %s, flagged or unreadable, outside the rule%s")
                                    :format(seed, step, cast.spell, id, was.member[id] and "" or ", not in your group"))
                                -- The storm's own favours returned by the rule (buff
                                -- mode off: only buff back casts).
                                if not staging and not was.buffMode and not was.iAmFlagged and id == cast.target
                                    and not cast.failed then
                                    per.storm = per.storm + 1
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
                    wow.press(button)
                    check(step, from, was)
                    return #wow.casts > from and wow.casts[#wow.casts] or nil
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
                local function pooled()
                    local i = random.random(#POOL)
                    return i, POOL[i]
                end
                local function roster()
                    hiddenSlot, hiddenName = nil, nil
                    local names = {}
                    for _, name in ipairs(POOL) do
                        if random.random() < 0.5 then names[#names + 1] = name end
                    end
                    local kind = random.random(2) == 1 and "party" or "raid"
                    if kind == "party" then while #names > 4 do table.remove(names, random.random(#names)) end end
                    wow.setGroup(kind, names)
                    for _, token in ipairs(others()) do
                        wow.state.units[token].subgroup = random.random(2)
                        if random.random() < 0.2 then wow.zoneOut(token) end
                    end
                    sync()
                    wow.fire("GROUP_ROSTER_UPDATE")
                end
                local actions = {
                    roster, roster,
                    -- Someone from the pool, shown on their own nameplate, buffs you.
                    function()
                        local i, name = pooled()
                        show("nameplate" .. i, name, { class = "PRIEST" })
                        sync()
                        owe("nameplate" .. i)
                    end,
                    function()
                        local i, name = pooled()
                        show("nameplate" .. i, name, { class = "PRIEST" })
                        sync()
                        owe("nameplate" .. i)
                    end,
                    -- Their nameplate goes, or comes back.
                    function()
                        local i = pooled()
                        wow.state.units["nameplate" .. i] = nil
                        wow.fire("NAME_PLATE_UNIT_REMOVED", "nameplate" .. i)
                    end,
                    function()
                        local i, name = pooled()
                        show("nameplate" .. i, name, { class = "PRIEST" })
                        sync()
                        wow.fire("NAME_PLATE_UNIT_ADDED", "nameplate" .. i)
                    end,
                    function()
                        local _, name = pooled()
                        flags[name] = { pvp = random.random() < 0.6, secret = random.random() < 0.15 }
                        sync()
                    end,
                    function()
                        local _, name = pooled()
                        flags[name] = { pvp = true }
                        sync()
                    end,
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
                    member(function(u) u.dead = random.random() < 0.2 end),
                    member(function(u)
                        u.secrets = random.random() < 0.3 and ({ { hidden = true }, { offline = true } })[random.random(2)]
                            or nil
                        sync()
                    end),
                    function() wow.state.pvp = false end,
                    function() wow.state.pvp = false end,
                    function() wow.state.pvp = random.random() < 0.2 end,
                    function() wow.state.inInstanceSecret = random.random() < 0.2 end,
                    function() wow.state.unitsRestricted = random.random() < 0.1 end,
                    function() hiddenSlot = random.random() < 0.3 and anyone() or nil end,
                    function() hiddenName = random.random() < 0.3 and anyone() or nil end,
                    function() myFlagHidden = random.random() < 0.2 end,
                    function() raidLies = random.random() < 0.4 end,
                    function() wow.loseBuff(INTELLECT) end,
                    function() if wow.state.inCombat then wow.leaveCombat() else wow.enterCombat() end end,
                    function() if wow.state.inCombat then wow.leaveCombat() end end,
                    function() slash(random.random() < 0.5 and "buffmode on" or "buffmode off") end,
                    function() wow.advance(random.random() * 20) end,
                    function() wow.fire("GROUP_ROSTER_UPDATE") end,
                }

                -- A staged scene: two players the storm has never met buff
                -- you as strangers, then join your group with two more. One
                -- is flagged and the other (the control) isn't; you aren't.
                -- Outside the rule, pressing until the button is empty must
                -- never reach the flagged one; it counts as refused when the
                -- control's favour was returned. Inside it, a favour returned
                -- to the flagged one is counted.
                local staged = 0
                local function stage(step, kind)
                    staged = staged + 1
                    staging = true
                    hiddenSlot, hiddenName, myFlagHidden, raidLies = nil, nil, false, false
                    if wow.state.inCombat then wow.leaveCombat() end
                    wow.state.inInstanceSecret, wow.state.unitsRestricted, wow.state.pvp = false, false, false
                    wow.leaveDungeon()
                    wow.setGroup(nil, {})
                    wow.fire("GROUP_ROSTER_UPDATE")
                    slash("buffmode off")
                    local tag = string.char(64 + math.ceil(staged / 26), 97 + (staged - 1) % 26)
                    local flagged, control = "Kit-" .. tag, "Lee-" .. tag
                    local plate = 9 + (staged * 2) % 30
                    local flaggedPlate, controlPlate = "nameplate" .. plate, "nameplate" .. (plate + 1)
                    show(flaggedPlate, flagged, { class = "PRIEST" })
                    show(controlPlate, control, { class = "PRIEST" })
                    owe(flaggedPlate)
                    owe(controlPlate)
                    local names = { flagged, control, "Mo-" .. tag, "Nan-" .. tag }
                    if kind == "a dungeon, not in your group" then names[1] = "Oz-" .. tag end
                    if kind == "a battleground" then
                        wow.enterBattleground(names) -- before the gates open
                    else
                        wow.setGroup(kind:find("raid") and "raid" or "party", names)
                        wow.fire("GROUP_ROSTER_UPDATE")
                    end
                    flags[flagged] = { pvp = true, secret = kind:find("their flag unreadable") ~= nil }
                    flags[control] = { pvp = false }
                    sync()
                    local list = others()
                    local flaggedSlot, otherSlot
                    for _, token in ipairs(list) do
                        local id = wow.state.units[token].id
                        if id == flagged then flaggedSlot = token end
                        if id == "Nan-" .. tag then otherSlot = token end
                    end
                    if kind == "an arena" then
                        wow.enterDungeon(nil, nil, "arena")
                    elseif kind:find("one outside") then
                        wow.zoneOut(otherSlot)
                    elseif kind == "a dungeon, one offline" then
                        wow.state.units[otherSlot].offline = true
                    elseif kind == "a dungeon, a connection unreadable" then
                        wow.state.units[otherSlot].secrets = { offline = true }
                    elseif kind == "a dungeon, sight unreadable" then
                        wow.state.units[otherSlot].secrets = { hidden = true }
                    end
                    if kind:find("^a dungeon") then wow.enterDungeon(DEADMINES, "The Deadmines") end
                    if kind:find("^a raid") then wow.enterRaid(MOLTEN_CORE, "Molten Core") end
                    if kind == "a dungeon the game won't name" then wow.state.inInstanceSecret = true end
                    if kind == "a dungeon, a slot unreadable" then hiddenSlot = otherSlot end
                    if kind == "a dungeon, their name in the group unreadable" then hiddenName = flaggedSlot end
                    if kind == "the open world, your flag unreadable" then myFlagHidden = true end
                    if kind:find("IsInRaid lying") then raidLies = true end
                    local reachedFlagged, reachedControl = false, false
                    local label = step .. " (" .. kind .. ")"
                    for _ = 1, 8 do
                        local cast = press(label)
                        if not cast then break end
                        if cast.target == flagged and not cast.failed then reachedFlagged = true end
                        if cast.target == control and not cast.failed then reachedControl = true end
                    end
                    local inside = false
                    for _, k in ipairs(INSIDE) do inside = inside or k == kind end
                    if inside then
                        per.insideScenes = per.insideScenes + 1
                        if reachedFlagged then
                            per.returned, total.returned = per.returned + 1, total.returned + 1
                        end
                    else
                        assert.is_false(reachedFlagged, ("seed %d, step %s: the flagged favour was returned"):format(seed, label))
                        per.scenes[kind] = (per.scenes[kind] or 0) + 1
                        if reachedControl then per.refused[kind] = (per.refused[kind] or 0) + 1 end
                    end
                    if kind == "a battleground" then wow.leaveBattleground() end
                    staging = false
                end

                for step = 1, 680 do
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
                -- Every staged scene counts: each outside one returned the
                -- control's favour and refused the flagged one, and each
                -- inside one returned the flagged one's.
                for _, kind in ipairs(OUTSIDE) do
                    local scenes, refused = per.scenes[kind] or 0, per.refused[kind] or 0
                    assert.is_true(scenes >= 3 and refused == scenes, ("seed %d refused a flagged favour in %s %d times of %d")
                        :format(seed, kind, refused, scenes))
                end
                assert.is_true(per.insideScenes >= 9 and per.returned == per.insideScenes,
                    ("seed %d: %d favours returned to a flagged member inside, of %d"):format(seed, per.returned, per.insideScenes))
                assert.is_true(per.storm >= 2, ("seed %d: the storm returned %d favours to a flagged member inside")
                    :format(seed, per.storm))
            end
            assert.is_true(total.casts > 500, "casts: " .. total.casts)
        end)
    end)
end)
