-- Spec: #329
-- Buff mode when solo: in no group, buff mode still offers you your own copy
-- of the buffs you give, as #198 does in a group, under the same rules (your
-- buff order, Never offer, who gets each buff, top-up time), single versions
-- only, never a group version. Someone else's copy on you counts as yours
-- until it runs low (the owner's answer 2 on #329).
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local ITEM = wow.ITEM
local FORT, FORT_1, PRAYER_FORT = 10938, 1243, 21564
local SPIRIT = 27841
local MOTW, THORNS = 9885, 467
local MIGHT, WISDOM = 25291, 25290
local BREATH = 5697

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

local function printedHas(fragment)
    for _, line in ipairs(wow.printed) do
        if line:find(fragment, 1, true) then return true end
    end
    return false
end

describe("Buff mode when solo: your own buffs (#329)", function()
    local ns, button

    -- A class (a priest unless said) who knows `known` (spell IDs), solo, in
    -- buff mode unless opts.noMode, offering your own buffs (#198).
    local function boot(opts)
        opts = opts or {}
        ns = wow.boot({ db = opts.db, buffSelf = true, buffDefaults = opts.buffDefaults, autoBuffMode = opts.auto,
            before = function(state)
                state.class = opts.class or "PRIEST"
                state.knownSpells = {}
                for _, id in ipairs(opts.known or { FORT, SPIRIT }) do state.knownSpells[id] = true end
                state.items = opts.items or {}
                if opts.before then opts.before(state) end
            end })
        button = ns.BuffButton.Frame()
        if not opts.noMode then slash("buffmode on") end
    end

    local function macro() return button:GetAttribute(ns.BuffButton.SECURE_ATTRIBUTE.leftButtonMacroText) end
    local function refresh() ns.BuffButton.Refresh() end
    local function subtitle() return button.subtitle:GetText() end

    -- The spell the armed button casts on you, after a fresh look: nil when
    -- it holds nothing; an error when it would cast on anyone else.
    local function armed()
        refresh()
        local text = macro()
        if not text then return nil end
        local spell = text:match("^/cast %[@player,nodead%] ([^\n]+)$")
        assert(spell, "not a cast on you: " .. text)
        return spell
    end

    -- Press the lent key once, and let the buff land on you: the cast.
    local function press()
        local before = #wow.casts
        wow.pressKey("MOUSEWHEELUP")
        local cast = wow.casts[before + 1]
        if cast and not cast.failed and cast.target == "Me" then
            wow.gainBuff({ spellId = cast.id, sourceUnit = "player" })
        end
        return cast
    end

    -- A buff on you: yours unless source says otherwise (false: a caster the
    -- game doesn't name), with left seconds of its 30 minutes to go.
    local function wear(id, source, left)
        local aura = { spellId = id, sourceUnit = source == nil and "player" or source or nil }
        if left then aura.duration, aura.expirationTime = 1800, wow.now + left end
        return wow.gainBuff(aura)
    end

    describe("what it offers (white)", function()
        it("offers a buff of yours you're missing on you, and a press casts it without touching your target", function()
            boot()
            assert.are.equal("Power Word: Fortitude", armed())
            assert.are.equal("/cast [@player,nodead] Power Word: Fortitude", macro())
            assert.are.equal("You", button.title:GetText())
            local cast = press()
            assert.are.equal(FORT, cast.id)
            assert.are.equal("Me", cast.target)
            assert.is_nil(cast.failed)
            assert.is_falsy(macro():find("target", 1, true), "no targeting in the macro")
            assert.are.same({}, wow.errors)
        end)

        it("offers them in your buff order, one per press, then is settled: you have your buffs", function()
            boot()
            assert.are.equal("Power Word: Fortitude", armed())
            press()
            assert.are.equal("Divine Spirit", armed())
            press()
            assert.is_nil(armed())
            assert.are.equal("you have your buffs", subtitle())
            local none, why, settled = ns.GroupBuffs.Next()
            assert.is_nil(none)
            assert.are.equal("you have your buffs", why)
            assert.is_true(settled)

            boot()
            ns.Options.MoveBuff("spirit", -1)
            assert.are.equal("Divine Spirit", armed(), "your order decides")
        end)

        it("tops up one running low under the top-up time, leaves one with more left, and with 0 waits until it's gone", function()
            boot()
            wear(SPIRIT)
            local fort = wear(FORT, "player", 6 * 60)
            assert.is_nil(armed(), "6 minutes left, top-up at 5")
            fort.expirationTime = wow.now + 4 * 60
            assert.are.equal("Power Word: Fortitude", armed(), "4 minutes left: topped up")
            ns.db.buffBack.topUpMinutes = 0
            assert.is_nil(armed(), "top-up 0: only once it's gone")
            wow.state.playerAuras = { wow.state.playerAuras[1] }
            assert.are.equal("Power Word: Fortitude", armed())
        end)

        it("comes after a favour you owe", function()
            boot()
            wow.addUnit("nameplate1", { name = "Bob", surname = "Stone", id = "Bob-Stone", class = "WARRIOR" })
            wow.gainBuff({ sourceUnit = "nameplate1", spellId = MOTW })
            refresh()
            assert.is_truthy(macro():find("/targetexact Bob Stone", 1, true))
            assert.are.equal("Bob-Stone", press().target)
            assert.are.equal("Power Word: Fortitude", armed())
        end)

        it("is a \"You\" row in the clickable list", function()
            boot()
            refresh()
            local offers = ns.BuffList.ShownOffers()
            assert.are.equal(1, #offers)
            assert.is_true(offers[1].self)
            assert.is_truthy(ns.BuffList.Rows()[1].text:GetText():find("You", 1, true))
        end)

        it("never offers a group version, with group versions on, known, a reagent, and one missing enough", function()
            boot({ known = { FORT, PRAYER_FORT }, items = { [ITEM.sacredCandle] = 5 } })
            ns.db.buffBack.groupVersions = true
            ns.db.buffBack.groupEnough = 1
            assert.are.equal("Power Word: Fortitude", armed())
            -- Not even looked at: no group version's reason rides on the offer.
            local offer = ns.GroupBuffs.Next()
            assert.is_nil(offer.note)
            assert.is_nil(offer.hint)
            assert.is_nil(offer.cast)
            local cast = press()
            assert.are.equal(FORT, cast.id)
            assert.are.equal(5, wow.state.items[ITEM.sacredCandle], "no candle used")
        end)

        it("offers the highest rank you know, by its name", function()
            boot({ known = { FORT_1 } })
            assert.are.equal("Power Word: Fortitude", armed())
            assert.are.equal(FORT_1, press().id)
        end)
    end)

    describe("your rules apply to you solo (white)", function()
        it("Never offer leaves a buff out", function()
            boot()
            ns.Options.SetNeverOffer("fortitude", true)
            assert.are.equal("Divine Spirit", armed())
            ns.Options.SetNeverOffer("spirit", true)
            assert.is_nil(armed())
            assert.are.equal("you're not in a group", subtitle(), "nothing of yours left to offer")
        end)

        it("your name on a buff's Never list leaves it out; on its Always list, a rule that leaves you out is passed over", function()
            boot()
            local me = ns.Util.UnitFullName("player")
            ns.BuffRules.AddName("fortitude", "never", me)
            assert.are.equal("Divine Spirit", armed())
            ns.BuffRules.SetRule("spirit", "tanks")
            assert.is_nil(armed(), "not a tank: no Spirit")
            ns.BuffRules.AddName("spirit", "always", me)
            assert.are.equal("Divine Spirit", armed(), "always")
        end)

        it("tanks only and everyone but tanks follow the role the game gives you", function()
            boot()
            ns.Options.SetNeverOffer("spirit", true)
            ns.BuffRules.SetRule("fortitude", "tanks")
            assert.is_nil(armed(), "no role: not a tank")
            wow.state.units.player.role = "TANK"
            assert.are.equal("Power Word: Fortitude", armed())
            ns.BuffRules.SetRule("fortitude", "notTanks")
            assert.is_nil(armed(), "a tank: left out")
            wow.state.units.player.role = "DAMAGER"
            assert.are.equal("Power Word: Fortitude", armed())
        end)

        it("chosen classes go by your class", function()
            boot()
            ns.Options.SetNeverOffer("spirit", true)
            ns.BuffRules.SetRule("fortitude", "classes")
            ns.BuffRules.SetClass("fortitude", "PRIEST", false)
            assert.is_nil(armed())
            ns.BuffRules.SetClass("fortitude", "PRIEST", true)
            assert.are.equal("Power Word: Fortitude", armed())
        end)

        it("with the defaults, a druid isn't offered Thorns (tanks only) unless the game says you tank", function()
            boot({ class = "DRUID", known = { MOTW, THORNS }, buffDefaults = true })
            assert.are.equal("Mark of the Wild", armed())
            press()
            assert.is_nil(armed())
            wow.state.units.player.role = "TANK"
            assert.are.equal("Thorns", armed())
        end)

        it("a paladin is offered only the first Blessing in their order, and none while wearing one of theirs", function()
            -- With the defaults, Wisdom (a mana class's, paladins ticked) is first.
            boot({ class = "PALADIN", known = { MIGHT, WISDOM }, buffDefaults = true })
            assert.are.equal("Blessing of Wisdom", armed())
            press()
            assert.is_nil(armed(), "one Blessing each")
            -- Paladins unticked for Wisdom: its default classes leave you out, so Might.
            boot({ class = "PALADIN", known = { MIGHT, WISDOM }, buffDefaults = true })
            ns.BuffRules.SetClass("wisdom", "PALADIN", false)
            assert.are.equal("Blessing of Might", armed())
            -- And the order decides between the two.
            boot({ class = "PALADIN", known = { MIGHT, WISDOM } })
            ns.Options.MoveBuff("might", -1)
            assert.are.equal("Blessing of Might", armed(), "Might moved first")
            ns.Options.MoveBuff("might", 1)
            assert.are.equal("Blessing of Wisdom", armed(), "Wisdom moved back first")
        end)

        it("Unending Breath waits for water", function()
            boot({ class = "WARLOCK", known = { BREATH } })
            assert.is_nil(armed())
            assert.are.equal("Unending Breath waits until you're near water", subtitle())
            wow.swim()
            assert.are.equal("Unending Breath", armed())
        end)

        it("the Buff Back tab's switch saves and takes effect at once, both ways, and is only on that tab", function()
            boot()
            local w = ns.Options.widgets
            wow.run(w.tabs.buffBack, "OnClick")
            assert.is_true(w.soloOwnBuffs:IsShown())
            assert.is_true(w.soloOwnBuffs:GetChecked())
            assert.are.equal("Power Word: Fortitude", armed())
            w.soloOwnBuffs:SetChecked(false)
            wow.run(w.soloOwnBuffs, "OnClick", "LeftButton")
            assert.is_false(ns.db.buffBack.soloOwnBuffs)
            assert.is_nil(macro())
            assert.are.equal("you're not in a group", subtitle())
            w.soloOwnBuffs:SetChecked(true)
            wow.run(w.soloOwnBuffs, "OnClick", "LeftButton")
            assert.is_true(ns.db.buffBack.soloOwnBuffs)
            assert.are.equal("/cast [@player,nodead] Power Word: Fortitude", macro())
            wow.run(w.tabs.buff, "OnClick")
            assert.is_false(w.soloOwnBuffs:IsShown())
            -- Opened with it off, the box shows it off.
            ns.db.buffBack.soloOwnBuffs = false
            wow.run(w.tabs.buffBack, "OnClick")
            assert.is_false(w.soloOwnBuffs:GetChecked())
        end)

        it("never while you aren't offered your own buffs at all (GroupBuffs.SELF_ORDER off)", function()
            boot()
            ns.GroupBuffs.SELF_ORDER = "off"
            assert.is_nil(armed())
            local _, why, settled = ns.GroupBuffs.Next()
            assert.are.equal("you're not in a group", why)
            assert.is_true(settled)
        end)

        it("off, it changes nothing in a group (#198 still buffs you there)", function()
            boot()
            ns.db.buffBack.soloOwnBuffs = false
            wow.setGroup("party", { "Ann-Vale" })
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.advance(0)
            assert.are.equal("Power Word: Fortitude", armed())
        end)

        it("damaged mid-session it reads as off, never as on", function()
            boot()
            for _, junk in ipairs({ "yes", 1, {}, "true" }) do
                ns.db.buffBack.soloOwnBuffs = junk
                assert.is_nil(armed(), tostring(junk))
            end
            ns.db.buffBack = nil
            assert.is_false(ns.GroupBuffs.SoloOn(), "settings lost mid-session")
        end)

        it("is on by default, and a damaged saved value loads as the default", function()
            boot()
            assert.is_true(ns.db.buffBack.soloOwnBuffs)
            for _, junk in ipairs({ "yes", 1, {}, "true" }) do
                boot({ db = { buffBack = { soloOwnBuffs = junk } } })
                assert.is_true(ns.db.buffBack.soloOwnBuffs, tostring(junk))
            end
            boot({ db = { buffBack = { soloOwnBuffs = false } } })
            assert.is_false(ns.db.buffBack.soloOwnBuffs, "off stays off")
            assert.is_nil(armed())
        end)
    end)

    describe("someone else's copy on you (white, the owner's answer 2)", function()
        it("counts as yours until it runs low, then is topped up", function()
            boot()
            ns.Options.SetNeverOffer("spirit", true)
            for _, source in ipairs({ false, "nameplate1", "target" }) do
                wow.state.playerAuras = {}
                local aura = wear(FORT, source, 20 * 60)
                local none, _, settled = ns.GroupBuffs.Next()
                assert.is_nil(none, tostring(source))
                assert.is_true(settled, tostring(source))
                aura.expirationTime = wow.now + 60
                local offer = ns.GroupBuffs.Next()
                assert.are.equal("fortitude", offer and offer.buff.key, tostring(source) .. ": running low")
            end
        end)

        it("one stronger than any rank you know is never cast over, even running low", function()
            boot({ known = { FORT_1 } })
            ns.Options.SetNeverOffer("spirit", true)
            wear(FORT, false, 60)
            assert.is_nil(ns.GroupBuffs.Next())
            wow.state.playerAuras = {}
            wear(PRAYER_FORT, false, 60)
            assert.is_nil(ns.GroupBuffs.Next(), "a group version above what you know")
        end)
    end)

    describe("buff mode on and off (white)", function()
        it("buff mode a trigger turned on waits for your own buffs, then ends: you have your buffs", function()
            boot({ noMode = true })
            ns.Options.SetNeverOffer("spirit", true)
            ns.BuffMode.Set(true, { auto = true, why = "test" })
            assert.is_true(ns.BuffMode.IsOn(), "your Fortitude is missing")
            refresh()
            assert.is_true(ns.BuffMode.IsOn())
            press()
            refresh()
            assert.is_false(ns.BuffMode.IsOn())
            assert.is_true(printedHas("buff mode off (you have your buffs)"))
        end)

        it("nothing solo turns buff mode on by itself", function()
            boot({ noMode = true, auto = true })
            for _ = 1, 5 do wow.advance(ns.BuffModeAuto.WATCH_SECONDS) end
            wow.enterCombat()
            wow.leaveCombat()
            wow.advance(1)
            assert.is_false(ns.BuffMode.IsOn())
            assert.are.equal(0, #wow.casts)
        end)

        it("joining a group is #198's, leaving one is solo again, with no reload", function()
            boot()
            ns.Options.SetNeverOffer("spirit", true)
            wear(FORT)
            wow.setGroup("party", { "Ann-Vale" })
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.advance(0)
            refresh()
            assert.is_truthy(macro():find("/targetexact Ann Vale", 1, true), "the group member")
            wow.state.playerAuras = {}
            wow.setGroup(nil, {})
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.advance(0)
            assert.are.equal("Power Word: Fortitude", armed())
        end)
    end)

    describe("what can't be read or done (black)", function()
        it("your auras restricted, a secret aura, spell ID or caster: nothing is offered, never errors, not settled", function()
            local cases = {
                restricted = function() wow.state.aurasRestricted = true end,
                secretAura = function() wow.state.playerAuras = { wow.secret({ spellId = FORT }) } end,
                secretId = function() wow.state.playerAuras = { { spellId = wow.secret(FORT), isHelpful = true } } end,
                secretCaster = function()
                    wow.state.playerAuras = { { spellId = FORT, isHelpful = true, sourceUnit = wow.secret("player"),
                        duration = 1800, expirationTime = wow.now + 1800 } }
                end,
            }
            for name, hide in pairs(cases) do
                boot()
                ns.Options.SetNeverOffer("spirit", true)
                hide()
                assert.is_nil(armed(), name)
                local none, why, settled = ns.GroupBuffs.Next()
                assert.is_nil(none, name)
                assert.is_false(settled, name)
                assert.is_truthy(why and why:find("^You: "), name .. ": " .. tostring(why))
                assert.are.same({}, wow.errors, name)
            end
        end)

        it("secret or junk times never compare: it counts as worn, never renewed, and is settled (#42's rule)", function()
            for _, times in ipairs({
                { duration = wow.secret(1800), expirationTime = wow.secret(60) },
                { duration = "x", expirationTime = {} },
                { duration = 0 / 0, expirationTime = 0 / 0 },
            }) do
                boot()
                ns.Options.SetNeverOffer("spirit", true)
                local aura = wear(FORT)
                aura.duration, aura.expirationTime = times.duration, times.expirationTime
                assert.is_nil(armed())
                local none, why, settled = ns.GroupBuffs.Next()
                assert.is_nil(none)
                assert.are.equal("you have your buffs", why)
                assert.is_true(settled)
                assert.are.same({}, wow.errors)
            end
        end)

        it("your role or class can't be read: a rule that needs it offers nothing, and isn't settled", function()
            boot()
            ns.Options.SetNeverOffer("spirit", true)
            ns.BuffRules.SetRule("fortitude", "tanks")
            wow.state.units.player.secrets = { role = true, mainTank = true }
            assert.is_nil(armed())
            local _, why, settled = ns.GroupBuffs.Next()
            assert.are.equal("You: can't tell if you're a tank", why)
            assert.is_false(settled)

            boot()
            ns.Options.SetNeverOffer("spirit", true)
            ns.BuffRules.SetRule("fortitude", "classes")
            wow.state.class = nil
            assert.is_nil(armed())
            _, why, settled = ns.GroupBuffs.Next()
            assert.are.equal("You: can't see your class", why)
            assert.is_false(settled)
            assert.are.same({}, wow.errors)
        end)

        it("your name can't be read: nothing, not settled", function()
            boot()
            wow.state.units.player.secrets = { name = true }
            assert.is_nil(armed())
            local _, why, settled = ns.GroupBuffs.Next()
            assert.are.equal("You: your name can't be read", why)
            assert.is_false(settled)
        end)

        it("when the game won't say whether you're in a group, nothing is offered and it isn't settled", function()
            for _, flag in ipairs({ "inGroupUnreadable", "inRaidUnreadable" }) do
                boot()
                wow.state[flag] = true
                assert.is_nil(armed(), flag)
                local none, _, settled = ns.GroupBuffs.Next()
                assert.is_nil(none, flag)
                assert.is_false(settled, flag)
            end
        end)

        it("dead: nothing, the button says why, not settled", function()
            boot()
            wow.state.units.player.dead = true
            assert.is_nil(armed())
            assert.are.equal("You: you're dead", subtitle())
            local _, _, settled = ns.GroupBuffs.Next()
            assert.is_false(settled)
            wow.state.units.player.dead = false
            assert.are.equal("Power Word: Fortitude", armed())
        end)

        it("in combat nothing is armed, and it is again after the fight", function()
            boot()
            wow.enterCombat()
            refresh()
            assert.is_nil(macro())
            wow.pressKey("MOUSEWHEELUP")
            assert.are.equal(0, #wow.casts)
            wow.leaveCombat()
            assert.are.equal("Power Word: Fortitude", armed())
        end)

        it("right-click skips your own buffs for a while", function()
            boot()
            refresh()
            wow.press(button, "RightButton")
            assert.is_nil(armed())
            wow.advance(ns.GroupBuffs.SKIP_SECONDS + 1)
            assert.are.equal("Power Word: Fortitude", armed())
        end)
    end)

    describe("chaos (red)", function()
        it("auras, deaths, combat, settings, spells and groups in a storm: never errors, never casts in combat, "
            .. "solo only single versions on you, and heals to the right offer", function()
            for _, seed in ipairs({ 7, 23, 329, 4096 }) do
                local selfCasts = 0
                random.seed(seed)
                boot({ known = { FORT, SPIRIT, PRAYER_FORT }, items = { [ITEM.sacredCandle] = 20 } })
                ns.db.buffBack.groupEnough = 1
                local sources = { "player", false, "nameplate1", wow.secret("player") }
                -- Each damaging state is drawn afresh often and is the rarer
                -- answer, so the storm spends most of its presses solo, out of
                -- combat, with something to cast, where the solo rules bite.
                local actions = {
                    function() wow.state.playerAuras = {} end,
                    function() wow.state.playerAuras = {} end,
                    function() wow.state.playerAuras = {} end,
                    function()
                        local id = ({ FORT, SPIRIT, PRAYER_FORT, FORT_1 })[random.random(4)]
                        local left = random.random() < 0.5 and random.random(1, 1800) or nil
                        wear(id, sources[random.random(#sources)], left)
                    end,
                    function() wow.state.playerAuras[#wow.state.playerAuras + 1] = wow.secret({ spellId = FORT }) end,
                    function()
                        -- Junk: a spell ID or times that aren't numbers, or NaN.
                        local junk = ({
                            { spellId = "x", isHelpful = true },
                            { spellId = FORT, isHelpful = true, sourceUnit = "player", duration = "x", expirationTime = {} },
                            { spellId = SPIRIT, isHelpful = true, sourceUnit = "player", duration = 0 / 0,
                                expirationTime = 0 / 0 },
                        })[random.random(3)]
                        wow.state.playerAuras[#wow.state.playerAuras + 1] = junk
                    end,
                    function() wow.state.aurasRestricted = random.random() < 0.1 end,
                    function() wow.state.units.player.dead = random.random() < 0.1 end,
                    function() wow.state.units.player.role = ({ "TANK", "NONE", nil })[random.random(3)] end,
                    function()
                        ns.db.buffBack.topUpMinutes = ({ 0, 5, 30, "junk", -4 })[random.random(5)]
                    end,
                    function() ns.db.buffBack.soloOwnBuffs = ({ true, true, true, true, true, false, "junk" })[random.random(7)] end,
                    function() ns.BuffRules.SetRule("fortitude", ns.BuffRules.RULES[random.random(4)]) end,
                    function()
                        wow.state.knownSpells[SPIRIT] = random.random() < 0.7 or nil
                        wow.fire("SPELLS_CHANGED")
                    end,
                    function()
                        if random.random() < 0.75 then
                            wow.setGroup(nil, {})
                        else
                            wow.setGroup("party", { "Ann-Vale" })
                        end
                        wow.fire("GROUP_ROSTER_UPDATE")
                    end,
                    function()
                        if wow.state.inCombat then wow.leaveCombat() elseif random.random() < 0.4 then wow.enterCombat() end
                    end,
                    function() press() end,
                    function() press() end,
                    function() press() end,
                    function() press() end,
                    function() wow.press(button, random.random() < 0.95 and "LeftButton" or "RightButton") end,
                    function() slash(random.random() < 0.95 and "buffmode on" or "buffmode off") end,
                    function() wow.advance(random.random() * 8) end,
                }
                for step = 1, 1000 do
                    local before = #wow.casts
                    -- Worked out from the client's own state before the step.
                    local fighting = wow.state.inCombat
                    local solo = wow.state.groupType == nil
                    actions[random.random(#actions)]()
                    for i = before + 1, #wow.casts do
                        local cast = wow.casts[i]
                        local where = ("seed %d, step %d: %s on %s"):format(seed, step, cast.spell, tostring(cast.target))
                        assert.is_falsy(fighting, where .. ", in combat")
                        if solo then
                            assert.are.equal("Me", cast.target, where .. ", solo")
                            assert.are_not.equal(PRAYER_FORT, cast.id, where .. ", a group version solo")
                            assert.is_nil(wow.GROUP_CASTS[cast.id], where .. ", a group version solo")
                            selfCasts = selfCasts + 1
                        end
                    end
                    -- What the button holds now, solo: never a group version,
                    -- and never you by name (a cast on you is [@player]).
                    local text = macro()
                    if text and wow.state.groupType == nil then
                        local where = ("seed %d, step %d: armed %q"):format(seed, step, text)
                        assert.is_falsy(text:find("Prayer of Fortitude", 1, true), where)
                        assert.is_falsy(text:find("/targetexact Me\n", 1, true), where)
                    end
                end
                assert.are.same({}, wow.errors, "seed " .. seed)
                -- The solo checks above saw enough casts to mean something.
                assert.is_true(selfCasts >= 10, ("seed %d: casts on you solo: %d"):format(seed, selfCasts))

                -- Heals: everything put right, solo, and the offer is the
                -- first buff you're missing, by the client's own state.
                if wow.state.inCombat then wow.leaveCombat() end
                wow.setGroup(nil, {})
                wow.fire("GROUP_ROSTER_UPDATE")
                wow.state.aurasRestricted = false
                wow.state.units.player.dead = false
                wow.state.units.player.role = nil
                wow.state.knownSpells[SPIRIT] = true
                wow.fire("SPELLS_CHANGED")
                ns.db.buffBack.soloOwnBuffs = true
                ns.db.buffBack.topUpMinutes = 5
                ns.BuffRules.SetRule("fortitude", "all")
                wow.state.playerAuras = {}
                wow.advance(ns.GroupBuffs.SKIP_SECONDS + 1)
                slash("buffmode on")
                assert.are.equal("Power Word: Fortitude", armed(), "seed " .. seed .. ": healed")
                wear(FORT)
                assert.are.equal("Divine Spirit", armed(), "seed " .. seed .. ": healed")
                wear(SPIRIT)
                assert.is_nil(armed(), "seed " .. seed .. ": healed")
                assert.are.equal("you have your buffs", subtitle(), "seed " .. seed)
            end
        end)
    end)
end)
