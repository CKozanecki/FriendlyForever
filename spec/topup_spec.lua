-- Spec: #42
-- Top-up timing: in buff mode, a group member's buff with less than the set
-- time left (default 5 minutes) counts as missing, so the button offers to
-- top it up. Group members only, never strangers; a time that can't be read
-- never counts as missing.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

-- Mark of the Wild (top rank and rank 1), Gift of the Wild, Thorns rank 1.
local MOTW, MOTW_1, GIFT, THORNS_1 = 9885, 1126, 21850, 467
local INTELLECT = 10157
local KINGS, MIGHT_1 = 20217, 19740
-- Mark of the Wild lasts 30 minutes.
local HALF_HOUR = 1800

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

describe("Top-up timing in buff mode (#42)", function()
    local ns, button

    -- A druid who knows Mark of the Wild (both ranks) and Thorns rank 1, in
    -- buff mode, with Ann Vale (and Cid Rock) in the party.
    local function boot(opts)
        opts = opts or {}
        ns = wow.boot({ db = opts.db, before = function(state)
            state.class = opts.class or "DRUID"
            state.knownSpells = opts.known or { [MOTW_1] = true, [MOTW] = true, [THORNS_1] = true }
        end })
        button = ns.BuffButton.Frame()
        if opts.buffMode ~= false then slash("buffmode on") end
        wow.setGroup("party", opts.party or { "Ann-Vale" })
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

    -- Ann wears spell, cast by source (default you; false: nobody the game
    -- names), with secondsLeft of duration (default half an hour) to go.
    local function annWears(spell, secondsLeft, duration, source)
        if source == nil then source = "player" end
        wow.wearBuff("party1", spell, { duration = duration or HALF_HOUR, source = source or nil })
        for i, id in ipairs(wow.state.units.party1.auras) do
            if id == spell then wow.state.units.party1.auraExpires[i] = wow.now + secondsLeft end
        end
    end

    -- Everything Ann needs, with plenty of time left.
    local function annHasAll()
        annWears(MOTW, HALF_HOUR)
        annWears(THORNS_1, 600, 600)
    end

    before_each(function() boot() end)

    describe("a buff running low is offered (white)", function()
        it("offers a buff with less time left than the threshold, and not one with more", function()
            annHasAll()
            annWears(MOTW, 4 * 60)
            assert.are.equal("Ann Vale: Mark of the Wild", armed(), "4 minutes left of 5")
            assert.are.equal("missing your Mark of the Wild", button.subtitle:GetText())
            annWears(MOTW, 6 * 60)
            assert.is_nil(armed(), "6 minutes left")
            assert.are.equal("everyone in your group has your buffs", button.subtitle:GetText())
        end)

        it("counts exactly the threshold as enough, and a second less as running low", function()
            annHasAll()
            annWears(MOTW, 300)
            assert.is_nil(armed(), "5:00 left")
            wow.advance(1)
            assert.are.equal("Ann Vale: Mark of the Wild", armed(), "4:59 left")
        end)

        it("defaults to 5 minutes, carried in the settings", function()
            assert.are.equal(5, ns.Config.DEFAULTS.buffBack.topUpMinutes)
            assert.are.equal(5, ns.db.buffBack.topUpMinutes)
        end)

        it("follows the setting: more minutes top up sooner, 0 never tops up", function()
            annHasAll()
            annWears(MOTW, 9 * 60)
            assert.is_nil(armed())
            ns.db.buffBack.topUpMinutes = 10
            assert.are.equal("Ann Vale: Mark of the Wild", armed(), "9 minutes left of 10")
            ns.db.buffBack.topUpMinutes = 0
            annWears(MOTW, 1)
            assert.is_nil(armed(), "0: only once it's gone")
            wow.advance(1)
            assert.are.equal("Ann Vale: Mark of the Wild", armed(), "gone: missing, as before")
        end)

        it("offers it as time runs out, with no event, at the button's next look", function()
            annHasAll()
            annWears(MOTW, 5 * 60 + 3)
            assert.is_nil(armed())
            wow.advance(ns.BuffButton.RECHECK_SECONDS + 1)
            assert.is_truthy(macro(), "armed by the button's own re-check")
            assert.is_truthy(macro():find("Mark of the Wild", 1, true))
        end)

        it("stops offering once the top-up lands and shows its full time again", function()
            annHasAll()
            annWears(MOTW, 60)
            assert.are.equal("Ann Vale: Mark of the Wild", armed())
            wow.pressKey("MOUSEWHEELUP")
            assert.are.equal(MOTW, wow.casts[#wow.casts].id)
            assert.are.equal("Ann-Vale", wow.casts[#wow.casts].target)
            -- The game shows the refreshed aura a moment later; until then it
            -- isn't offered again.
            assert.is_nil(armed(), "just given")
            wow.advance(2)
            annWears(MOTW, HALF_HOUR)
            wow.advance(ns.GroupBuffs.JUST_GIVEN_SECONDS)
            assert.is_nil(armed(), "renewed")
        end)

        it("tops up each member in group order, your first buff before your second", function()
            boot({ party = { "Ann-Vale", "Cid-Rock" } })
            wow.wearBuff("party1", MOTW, { duration = HALF_HOUR, source = "player" })
            wow.wearBuff("party1", THORNS_1, { duration = 600, source = "player" })
            wow.wearBuff("party2", MOTW, { duration = HALF_HOUR, source = "player" })
            wow.wearBuff("party2", THORNS_1, { duration = 600, source = "player" })
            assert.is_nil(armed())
            wow.advance(HALF_HOUR - 200) -- Thorns ran out long ago; Mark has 200 s left
            assert.are.equal("Ann Vale: Mark of the Wild", armed())
            wow.pressKey("MOUSEWHEELUP")
            assert.are.equal("Cid Rock: Mark of the Wild", armed())
            wow.pressKey("MOUSEWHEELUP")
            assert.are.equal("Ann Vale: Thorns", armed())
        end)

        it("tops up another caster's rank you can replace, and a rank your own cast matches", function()
            annWears(THORNS_1, 600, 600)
            annWears(MOTW_1, 60, HALF_HOUR, false)
            assert.is_nil(wow.state.units.party1.auraSources[2], "nobody the game names")
            assert.are.equal("Ann Vale: Mark of the Wild", armed(), "rank 1, by nobody the game names")
            boot({ known = { [MOTW_1] = true, [THORNS_1] = true } })
            annWears(THORNS_1, 600, 600)
            annWears(MOTW_1, 60, HALF_HOUR, "party1")
            assert.are.equal("Ann Vale: Mark of the Wild", armed(), "the rank you know")
            boot({ known = { [MOTW] = true, [THORNS_1] = true } })
            annWears(THORNS_1, 600, 600)
            annWears(MOTW_1, 60, HALF_HOUR, "party1")
            assert.are.equal("Ann Vale: Mark of the Wild", armed(), "a rank below the only one you know")
        end)

        it("lets a paladin renew their own Blessing, never swapping it for another", function()
            boot({ class = "PALADIN", known = { [KINGS] = true, [MIGHT_1] = true } })
            wow.state.units.party1.class = "WARRIOR"
            ns.db.buffBack.buffOrder = { "kings", "might" }
            wow.wearBuff("party1", MIGHT_1, { duration = 3600, source = "player" })
            assert.is_nil(armed(), "an hour of your Might: Kings would replace it")
            wow.advance(3600 - 120)
            assert.are.equal("Ann Vale: Blessing of Might", armed(), "your Might, not Kings, at 2 minutes left")
        end)
    end)

    describe("what it leaves alone (white)", function()
        it("leaves a higher rank than yours, a group version or a blocker to run out", function()
            boot({ known = { [MOTW_1] = true, [THORNS_1] = true } })
            annWears(THORNS_1, 600, 600)
            annWears(MOTW, 60)
            assert.is_nil(armed(), "a higher rank than you know")
            boot()
            annWears(THORNS_1, 600, 600)
            annWears(GIFT, 60, 3600)
            assert.is_nil(armed(), "Gift of the Wild")
            boot({ class = "MAGE", known = { [1459] = true, [INTELLECT] = true } })
            wow.wearBuff("party1", 8096, { duration = HALF_HOUR }) -- a Scroll of Intellect
            wow.state.units.party1.auraExpires[1] = wow.now + 60
            assert.is_nil(armed(), "a scroll")
            wow.advance(60)
            assert.are.equal("Ann Vale: Arcane Intellect", armed(), "once it's gone")
        end)

        it("never offers a buff no longer than the threshold, even near its end", function()
            ns.db.buffBack.topUpMinutes = 10
            annWears(MOTW, HALF_HOUR)
            annWears(THORNS_1, 60, 600)
            assert.is_nil(armed(), "10-minute Thorns with a 10-minute threshold")
            ns.db.buffBack.topUpMinutes = 5
            assert.are.equal("Ann Vale: Thorns", armed(), "with 5 minutes it is")
        end)

        it("leaves a buff that never runs out", function()
            annHasAll()
            wow.state.units.party1.auraDurations[1], wow.state.units.party1.auraExpires[1] = 0, 0
            assert.is_nil(armed())
        end)

        it("never tops up a stranger: buff back is unchanged", function()
            boot({ buffMode = false, party = {} })
            wow.addUnit("nameplate1", { name = "Bob", surname = "Stone", class = "WARRIOR", id = "Bob-Stone" })
            wow.wearBuff("nameplate1", MOTW, { duration = HALF_HOUR, source = "player" })
            wow.state.units.nameplate1.auraExpires[1] = wow.now + 30
            wow.gainBuff({ sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = INTELLECT })
            local offer = ns.Offers.Current()
            assert.are.equal("thorns", offer and offer.buff.key, "his Mark still counts, 30 s left or not")
            ns.Offers.Forget("Bob-Stone")
            slash("buffmode on")
            assert.is_nil(armed(), "and buff mode doesn't reach him")
        end)
    end)

    describe("time that can't be read (black)", function()
        it("doesn't count a buff as missing when its time left is secret", function()
            annHasAll()
            annWears(MOTW, 30)
            wow.state.units.party1.secrets = { auraTimes = true }
            assert.is_nil(armed())
            assert.are.equal("everyone in your group has your buffs", button.subtitle:GetText())
            wow.state.units.party1.auraDurations[1] = nil -- only the expiry, secret
            assert.is_nil(armed())
            assert.are.same({}, wow.errors)
        end)

        it("doesn't count it as missing when its time is missing or junk", function()
            annHasAll()
            local u = wow.state.units.party1
            for _, case in ipairs({
                { nil, wow.now + 30 }, { HALF_HOUR, nil }, { "1800", wow.now + 30 }, { HALF_HOUR, "soon" },
                { HALF_HOUR, {} }, { 0 / 0, wow.now + 30 }, { HALF_HOUR, 0 / 0 }, { HALF_HOUR, math.huge },
                { -1, wow.now + 30 }, { HALF_HOUR, -5 }, { true, wow.now + 30 }, { HALF_HOUR, 0 },
            }) do
                u.auraDurations[1], u.auraExpires[1] = case[1], case[2]
                assert.is_nil(armed(), tostring(case[1]) .. ", " .. tostring(case[2]))
            end
            assert.are.same({}, wow.errors)
        end)

        it("renews a Blessing whose caster is secret (the same Blessing only refreshes), never another", function()
            boot({ class = "PALADIN", known = { [KINGS] = true, [MIGHT_1] = true } })
            ns.db.buffBack.buffOrder = { "might", "kings" }
            wow.wearBuff("party1", KINGS, { duration = 3600, source = wow.secret("player") })
            wow.state.units.party1.auraExpires[1] = wow.now + 60
            assert.are.equal("Ann Vale: Blessing of Kings", armed())
            wow.state.units.party1.auraExpires[1] = wow.now + 600
            assert.is_nil(armed(), "with time left: whose it is can't be told, so no Might over it")
            assert.are.equal("Ann Vale: can't tell whose Blessing they have", button.subtitle:GetText())
            assert.are.same({}, wow.errors)
        end)

        it("repairs a damaged setting at load, and reads one damaged mid-session as the default", function()
            for _, bad in ipairs({ "ten", -5, {}, true, 0 / 0 }) do
                boot({ db = { buffBack = { topUpMinutes = bad } } })
                assert.are.equal(type(bad) == "number" and bad == bad and 0 or 5, ns.db.buffBack.topUpMinutes,
                    tostring(bad))
            end
            boot({ db = { buffBack = { topUpMinutes = 999 } } })
            assert.are.equal(ns.Config.LIMITS.topUpMinutes.max, ns.db.buffBack.topUpMinutes)
            annHasAll()
            annWears(MOTW, 4 * 60)
            ns.db.buffBack.topUpMinutes = "five"
            assert.are.equal("Ann Vale: Mark of the Wild", armed(), "the default, 5")
            annWears(MOTW, 5 * 60 + 30)
            assert.is_nil(armed(), "5:30 left: the default is 5, no more")
            annWears(MOTW, 4 * 60)
            ns.db.buffBack.topUpMinutes = 4.9
            assert.is_nil(armed(), "whole minutes: 4")
            ns.db.buffBack.topUpMinutes = 0 / 0
            assert.are.equal("Ann Vale: Mark of the Wild", armed(), "NaN: the default")
            assert.are.same({}, wow.errors)
        end)

        it("goes with profiles and export, and an import is checked", function()
            ns.db.buffBack.topUpMinutes = 12
            local text = ns.Profiles.Export()
            ns.db.buffBack.topUpMinutes = 3
            assert.is_true((ns.Profiles.Import(text)))
            assert.are.equal(12, ns.db.buffBack.topUpMinutes)
            local damaged = ns.Profiles.Snapshot(ns.db)
            damaged.buffBack.topUpMinutes = 400
            assert.is_true((ns.Profiles.Import(ns.Serialize.Encode({ v = 1, settings = damaged }))))
            assert.are.equal(ns.Config.LIMITS.topUpMinutes.max, ns.db.buffBack.topUpMinutes)
        end)
    end)

    describe("the setting on the Buff Back tab", function()
        it("shows only on that tab, below buff mode's minutes, and steps within its limits", function()
            ns.Options.Create()
            local w = ns.Options.widgets
            wow.run(w.tabs.buffBack, "OnClick")
            local s = w.steppers.topUpMinutes
            assert.is_true(s.box:IsShown())
            assert.are.equal("5", s.box:GetText())
            assert.are.equal(w.steppers.autoOffMinutes.label, select(2, s.label:GetPoint()))
            wow.run(s.plus, "OnClick")
            assert.are.equal(6, ns.db.buffBack.topUpMinutes)
            for _ = 1, 20 do wow.run(s.minus, "OnClick") end
            assert.are.equal(0, ns.db.buffBack.topUpMinutes)
            s.box:SetText("99")
            wow.run(s.box, "OnEditFocusLost")
            assert.are.equal(15, ns.db.buffBack.topUpMinutes)
            wow.run(w.tabs.buff, "OnClick")
            assert.is_false(s.box:IsShown())
            assert.is_false(s.label:IsShown())
        end)

        it("saves a number being typed before a reset puts the default back", function()
            ns.Options.Create()
            local w = ns.Options.widgets
            wow.run(w.tabs.buffBack, "OnClick")
            local box = w.steppers.topUpMinutes.box
            box:SetFocus()
            box:SetText("9")
            wow.run(w.reset, "OnClick")
            assert.are.equal(5, ns.db.buffBack.topUpMinutes, "the reset wins")
            assert.are.equal("5", box:GetText())
        end)
    end)

    describe("chaos (red tests)", function()
        -- Every Mark of the Wild there is (both ranks, Gift of the Wild).
        local COVERS = { [MOTW] = true, [MOTW_1] = true, [GIFT] = true }

        -- Whether the client's own state says Ann may be offered Mark of the
        -- Wild: no live Mark at all, or every live one is a rank you know
        -- with readable times, longer than the threshold, and less of it left.
        local function mayOffer(u, threshold)
            for i, id in ipairs(u.auras or {}) do
                if COVERS[id] and not wow.auraExpired(u, i) then
                    local duration, expires = u.auraDurations and u.auraDurations[i], u.auraExpires and u.auraExpires[i]
                    if threshold <= 0 or id == GIFT then return false end
                    if u.secrets and u.secrets.auraTimes then return false end
                    if type(duration) ~= "number" or type(expires) ~= "number" then return false end
                    if duration ~= duration or expires ~= expires then return false end
                    if duration <= threshold or expires <= 0 or expires - wow.now >= threshold then return false end
                end
            end
            return true
        end

        it("time running out and clock changes never cause errors or a top-up the state forbids", function()
            -- topUps: casts over a live Mark; held: steps near its end that
            -- the state forbids (secret or junk times, Gift, a short buff, 0).
            local topUps, held = 0, 0
            for _, seed in ipairs({ 3, 42, 99, 512, 2026, 7777 }) do
                random.seed(seed)
                boot({ known = { [MOTW] = true, [MOTW_1] = true } })
                local u = wow.state.units.party1
                -- Settings changes are seen at the next look, as from the options.
                local actions = {
                    function()
                        local spell = ({ MOTW, MOTW, MOTW, MOTW_1, GIFT })[random.random(5)]
                        wow.wearBuff("party1", spell, { duration = ({ HALF_HOUR, HALF_HOUR, 3600, 240, 0 })[random.random(5)],
                            source = random.random() < 0.7 and "player" or nil })
                        ns.BuffButton.Refresh()
                    end,
                    -- A Mark of yours near its end, either side of the threshold.
                    function()
                        wow.wearBuff("party1", MOTW, { duration = HALF_HOUR, source = "player" })
                        for i, id in ipairs(u.auras) do
                            if id == MOTW then u.auraExpires[i] = wow.now + random.random(1, 600) end
                        end
                        ns.BuffButton.Refresh()
                    end,
                    function()
                        if u.auras and #u.auras > 0 then
                            u.auraExpires[random.random(#u.auras)] = wow.now + random.random(0, 600)
                        end
                        ns.BuffButton.Refresh()
                    end,
                    function()
                        if u.auras and #u.auras > 0 then
                            local i = random.random(#u.auras)
                            local junk = { "x", {}, 0 / 0, math.huge, -1, true }
                            if random.random() < 0.5 then u.auraDurations[i] = junk[random.random(#junk)]
                            else u.auraExpires[i] = junk[random.random(#junk)] end
                        end
                        ns.BuffButton.Refresh()
                    end,
                    function()
                        u.secrets = random.random() < 0.3 and { auraTimes = true } or nil
                        ns.BuffButton.Refresh()
                    end,
                    function()
                        ns.db.buffBack.topUpMinutes = ({ 0, 1, 5, 5, 10, 15, "x", -3, 99 })[random.random(9)]
                        ns.BuffButton.Refresh()
                    end,
                    function() u.auras, u.auraSources, u.auraDurations, u.auraExpires = nil, nil, nil, nil end,
                    -- The wall clock jumps either way; the game clock never goes back.
                    function() wow.state.clock = wow.state.clock + random.random(-86400, 86400) end,
                    function() wow.advance(random.random() * 400) end,
                    function() wow.advance(random.random() * 10) end,
                    function() wow.pressKey("MOUSEWHEELUP") end,
                    function() wow.pressKey("MOUSEWHEELUP") end,
                    function() wow.pressKey("MOUSEWHEELUP") end,
                    function()
                        if wow.state.inCombat then wow.leaveCombat() elseif random.random() < 0.3 then wow.enterCombat() end
                    end,
                }
                for step = 1, 500 do
                    local before = #wow.casts
                    local limits = ns.Config.LIMITS.topUpMinutes
                    local minutes = ns.db.buffBack and ns.db.buffBack.topUpMinutes
                    if type(minutes) ~= "number" or minutes ~= minutes then minutes = 5 end
                    minutes = math.max(limits.min, math.min(limits.max, math.floor(minutes)))
                    local allowed = mayOffer(u, minutes * 60)
                    -- wore: a live Mark; nearEnd: one whose raw expiry is within
                    -- the threshold, held back or not.
                    local wore, nearEnd = false, false
                    for i, id in ipairs(u.auras or {}) do
                        if COVERS[id] and not wow.auraExpired(u, i) then
                            wore = true
                            local expires = u.auraExpires and u.auraExpires[i]
                            if type(expires) == "number" and expires > 0 and expires - wow.now < minutes * 60 then
                                nearEnd = true
                            end
                        end
                    end
                    actions[random.random(#actions)]()
                    for i = before + 1, #wow.casts do
                        local cast = wow.casts[i]
                        if cast.spell == "Mark of the Wild" then
                            assert.is_true(allowed, ("seed %d, step %d: Mark of the Wild on %s the state forbids")
                                :format(seed, step, cast.target))
                            if wore then topUps = topUps + 1 end
                            -- It lands: the aura shows its full time again.
                            wow.wearBuff("party1", cast.id, { duration = HALF_HOUR, source = "player" })
                        end
                    end
                    if nearEnd and not allowed then held = held + 1 end
                end
                assert.are.same({}, wow.errors, "seed " .. seed)
            end
            assert.is_true(topUps > 25, "top-ups: " .. topUps)
            assert.is_true(held > 200, "held: " .. held)
        end)
    end)
end)
