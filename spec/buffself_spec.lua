-- Spec: #198
-- Buff mode also buffs you: your own copy of each buff you give is offered
-- on you, after the group's, under the same rules.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local MOTW, MOTW_1, THORNS_1 = 9885, 1126, 467

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

describe("Buff mode buffing you too", function()
    local ns, button

    -- A druid who knows Mark of the Wild and Thorns, in buff mode, with
    -- the self buff on (older specs start with it off).
    local function boot(opts)
        opts = opts or {}
        ns = wow.boot({ db = opts.db, buffSelf = true, autoBuffMode = opts.auto, before = function(state)
            state.class = opts.class or "DRUID"
            state.knownSpells = opts.known or { [MOTW_1] = true, [MOTW] = true, [THORNS_1] = true }
        end })
        button = ns.BuffButton.Frame()
        if not opts.auto then slash("buffmode on") end
    end

    local function macro() return button:GetAttribute(ns.BuffButton.SECURE_ATTRIBUTE.leftButtonMacroText) end

    -- Who the armed button casts on: a name, or "me" for [@player].
    local function armed()
        local text = macro()
        if not text then return nil end
        local spell = text:match("/cast %[@player,nodead%] ([^\n]+)")
        if spell then return "me: " .. spell end
        return text:match("/targetexact ([^\n]+)") .. ": " .. text:match("/cast %[help,nodead%] ([^\n]+)")
    end

    -- Scroll once, and let the buff show on whoever it reached.
    local function scroll()
        local before = #wow.casts
        wow.pressKey("MOUSEWHEELUP")
        local cast = wow.casts[before + 1]
        if cast and not cast.failed then
            if cast.target == "Me" then
                wow.gainBuff({ spellId = cast.id, sourceUnit = "player" })
            else
                for token, u in pairs(wow.state.units) do
                    if u.id == cast.target and token ~= "target" then
                        u.auras = u.auras or {}
                        u.auras[#u.auras + 1] = cast.id
                        u.auraSources = u.auraSources or {}
                        u.auraSources[#u.auras] = "player"
                    end
                end
            end
        end
        return cast
    end

    local function party(names)
        wow.setGroup("party", names)
        wow.fire("GROUP_ROSTER_UPDATE")
        wow.advance(0)
    end

    local function wearEverything(unit)
        unit.auras, unit.auraSources = { MOTW, THORNS_1 }, { "player", "player" }
        ns.BuffButton.Refresh()
    end

    before_each(function() boot() end)

    describe("whom it offers", function()
        it("offers a buff you're missing on you when everyone else has it", function()
            party({ "Ann-Vale" })
            wearEverything(wow.state.units.party1)
            assert.are.equal("me: Mark of the Wild", armed())
            assert.are.equal("You", button.title:GetText())
            assert.are.equal("missing your Mark of the Wild", button.subtitle:GetText())
            local cast = scroll()
            assert.are.equal("Me", cast.target)
            assert.are.equal("Mark of the Wild", cast.spell)
        end)

        it("casts on you without changing your target", function()
            party({ "Ann-Vale" })
            wearEverything(wow.state.units.party1)
            wow.addUnit("target", { name = "Bob", surname = "Stone", id = "Bob-Stone" })
            ns.BuffButton.Refresh()
            local cast = scroll()
            assert.are.equal("Me", cast.target)
            assert.are.equal("Bob-Stone", wow.state.units.target.id)
            assert.is_nil(macro():find("target", 1, true), "the macro never touches targeting")
        end)

        it("offers each buff to you first and then the group, your first buff before anyone's second", function()
            party({ "Ann-Vale", "Cid-Rock" })
            local order = {}
            for _ = 1, 8 do
                local cast = scroll()
                if not cast then break end
                order[#order + 1] = cast.target .. " " .. cast.spell
            end
            assert.are.same({
                "Me Mark of the Wild", "Ann-Vale Mark of the Wild", "Cid-Rock Mark of the Wild",
                "Me Thorns", "Ann-Vale Thorns", "Cid-Rock Thorns",
            }, { unpack(order, 1, 6) }, "each buff goes to you, then the group; your first buff before anyone's second")
            assert.is_nil(order[7], "nothing more to cast")
            assert.is_nil(macro())
            assert.are.equal("everyone in your group has your buffs", button.subtitle:GetText())
        end)

        it("puts you after the group for each buff when SELF_ORDER says last (the one line that decides)", function()
            ns.GroupBuffs.SELF_ORDER = "last"
            party({ "Ann-Vale", "Cid-Rock" })
            local order = {}
            for _ = 1, 8 do
                local cast = scroll()
                if not cast then break end
                order[#order + 1] = cast.target .. " " .. cast.spell
            end
            assert.are.same({
                "Ann-Vale Mark of the Wild", "Cid-Rock Mark of the Wild", "Me Mark of the Wild",
                "Ann-Vale Thorns", "Cid-Rock Thorns", "Me Thorns",
            }, order)
        end)

        it("leaves you out when SELF_ORDER is off", function()
            ns.GroupBuffs.SELF_ORDER = "off"
            party({ "Ann-Vale" })
            wearEverything(wow.state.units.party1)
            ns.BuffButton.Refresh()
            assert.is_nil(macro())
        end)

        it("offers nothing extra when you have every buff, and buff mode has nothing left", function()
            party({ "Ann-Vale" })
            wearEverything(wow.state.units.party1)
            wow.gainBuff({ spellId = MOTW, sourceUnit = "player" })
            wow.gainBuff({ spellId = THORNS_1, sourceUnit = "player" })
            ns.BuffButton.Refresh()
            assert.is_nil(macro())
            local offer, why, settled = ns.GroupBuffs.Next()
            assert.is_nil(offer)
            assert.are.equal("everyone in your group has your buffs", why)
            assert.is_true(settled)
        end)

        it("counts a buff of anyone's that covers it as yours already", function()
            party({ "Ann-Vale" })
            wearEverything(wow.state.units.party1)
            wow.gainBuff({ spellId = MOTW, sourceUnit = "party1" })
            wow.gainBuff({ spellId = THORNS_1, sourceUnit = "party1" })
            ns.BuffButton.Refresh()
            assert.is_nil(macro())
        end)

        it("is not offered when you're in no group", function()
            ns.BuffButton.Refresh()
            assert.is_nil(macro())
            local _, why, settled = ns.GroupBuffs.Next()
            assert.are.equal("you're not in a group", why)
            assert.is_true(settled)
        end)

        it("buffs you in a raid too, once, though the raid has a slot for you", function()
            wow.setGroup("raid", { "Ann-Vale" })
            wow.addUnit("raid2", wow.state.units.player)
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.advance(0)
            local targets = {}
            for _ = 1, 6 do
                local cast = scroll()
                if cast then targets[#targets + 1] = cast.target end
            end
            assert.are.same({ "Me", "Ann-Vale", "Me", "Ann-Vale" }, targets)
        end)

        it("applies your buff order, Never list and who-gets-it rules to you", function()
            party({ "Ann-Vale" })
            wearEverything(wow.state.units.party1)
            local ok = ns.BuffRules.AddName("motw", "never", "Me")
            assert.is_true(ok)
            assert.are.equal("me: Thorns", armed(), "Mark of the Wild is on your own Never list")
        end)

        it("follows your who-gets-it rule for your own class", function()
            party({ "Ann-Vale" })
            wearEverything(wow.state.units.party1)
            wow.gainBuff({ spellId = MOTW, sourceUnit = "player" })
            ns.db.buffBack.whoGets.thorns = { rule = "classes", classes = { WARRIOR = true } }
            ns.BuffButton.Refresh()
            assert.is_nil(macro(), "Thorns is for warriors only, and you're a druid")
            ns.db.buffBack.whoGets.thorns = { rule = "classes", classes = { DRUID = true } }
            ns.BuffButton.Refresh()
            assert.are.equal("me: Thorns", armed())
        end)

        it("renews a buff of yours that's running low (top-up)", function()
            ns.db.buffBack.topUpMinutes = 5
            party({ "Ann-Vale" })
            wearEverything(wow.state.units.party1)
            wow.gainBuff({ spellId = MOTW, sourceUnit = "player", duration = 3600, expirationTime = wow.now + 120 })
            wow.gainBuff({ spellId = THORNS_1, sourceUnit = "player" })
            ns.BuffButton.Refresh()
            assert.are.equal("me: Mark of the Wild", armed())
        end)

        it("offers you even when the game says you're out of range of yourself", function()
            party({ "Ann-Vale" })
            wearEverything(wow.state.units.party1)
            wow.state.units.player.outOfSpellRange = true
            ns.BuffButton.Refresh()
            assert.are.equal("me: Mark of the Wild", armed())
        end)

        it("right-click skips you for a while like anyone else", function()
            party({ "Ann-Vale" })
            wearEverything(wow.state.units.party1)
            assert.are.equal("me: Mark of the Wild", armed())
            wow.press(button, "RightButton")
            assert.is_nil(macro())
            assert.is_true(select(3, ns.GroupBuffs.Next()), "skipping yourself leaves nothing to do, as for anyone")
            wow.advance(ns.GroupBuffs.SKIP_SECONDS + 1)
            assert.are.equal("me: Mark of the Wild", armed())
        end)
    end)

    describe("presses", function()
        it("reports the cast as given to you, and offers the next buff", function()
            party({ "Ann-Vale" })
            wearEverything(wow.state.units.party1)
            scroll()
            assert.are.equal("Gave Mark of the Wild to you.", button.result:GetText())
            assert.are.equal("me: Thorns", armed())
        end)

        it("describes a cast on you in the tooltip, not a target swap", function()
            party({ "Ann-Vale" })
            wearEverything(wow.state.units.party1)
            wow.run(button, "OnEnter")
            local text = {}
            for _, line in ipairs(_G.GameTooltip.lines or {}) do text[#text + 1] = type(line) == "table" and line.text or line end
            local all = table.concat(text, "\n")
            assert.is_truthy(all:find("on you; your target stays as it is", 1, true), all)
            assert.is_nil(all:find("gives you your target back", 1, true))
            assert.is_truthy(all:find("skip yourself", 1, true))
        end)

        it("says you, not your name, when the game doesn't answer or you skip", function()
            party({ "Ann-Vale" })
            wearEverything(wow.state.units.party1)
            wow.press(button, "RightButton")
            assert.are.equal("Skipping yourself for 5 minutes.", button.result:GetText())
        end)

        it("puts a Never mark on you in your own words (Shift+right-click)", function()
            party({ "Ann-Vale" })
            wearEverything(wow.state.units.party1)
            _G.IsShiftKeyDown = function() return true end
            wow.press(button, "RightButton")
            assert.are.equal("You won't get Mark of the Wild (Never list, on the Buff Back tab).", button.result:GetText())
        end)

        it("says so in your words when the Never mark can't be added", function()
            party({ "Ann-Vale" })
            wearEverything(wow.state.units.party1)
            _G.IsShiftKeyDown = function() return true end
            local add = ns.BuffRules.AddName
            ns.BuffRules.AddName = function() return false, "the list is full" end
            wow.press(button, "RightButton")
            ns.BuffRules.AddName = add
            assert.are.equal("Couldn't add you to the Never list: the list is full.", button.result:GetText())
        end)

        it("says you when the game never answers the cast", function()
            party({ "Ann-Vale" })
            wearEverything(wow.state.units.party1)
            wow.state.castLatency = 100 -- the server never answers within the wait
            wow.pressKey("MOUSEWHEELUP")
            wow.advance(ns.BuffButton.SENT_ANSWER_SECONDS + 1)
            assert.are.equal("No word back on Mark of the Wild for you. If it didn't land, press again.",
                button.result:GetText())
        end)

        it("holds you back for a moment when the game refuses the cast", function()
            party({ "Ann-Vale" })
            wearEverything(wow.state.units.party1)
            wow.state.castFailures.Me = "Invalid target"
            local cast = scroll()
            assert.is_truthy(cast.failed)
            assert.are.equal("Couldn't buff you: Invalid target", button.result:GetText())
            assert.is_nil(macro(), "held back for a moment")
            assert.is_false(select(3, ns.GroupBuffs.Next()), "you still need the buff, so buff mode stays on")
            wow.advance(ns.GroupBuffs.HELD_BACK_SECONDS + 1)
            assert.is_truthy(macro())
        end)
    end)

    describe("a paladin's Blessings", function()
        it("says 'you' when it can't tell whose Blessing is on you", function()
            local KINGS, MIGHT_1 = 20217, 19740
            boot({ known = { [KINGS] = true, [MIGHT_1] = true }, class = "PALADIN" })
            ns.db.buffBack.buffOrder = { "might", "kings" }
            party({ "Ann-Vale" })
            local ann = wow.state.units.party1
            ann.auras, ann.auraSources = { KINGS }, { "player" }
            wow.gainBuff({ spellId = KINGS, sourceUnit = wow.secret("party1") })
            ns.BuffButton.Refresh()
            assert.is_nil(macro())
            assert.are.equal("You: can't tell whose Blessing you have", select(2, ns.GroupBuffs.Next()))
        end)
    end)

    describe("buff mode ending (white)", function()
        it("doesn't end while you're missing a buff, and ends once you have it", function()
            boot({ auto = true })
            ns.db.buffBack.autoOnJoin = true
            ns.db.buffBack.autoOffDone = true
            wow.state.knownSpells = { [MOTW_1] = true, [MOTW] = true }
            ns.BuffData.SpellsChanged()
            wow.setGroup("party", { "Ann-Vale" })
            wearEverything(wow.state.units.party1)
            wow.state.units.party1.auras = { MOTW }
            wow.state.units.party1.auraSources = { "player" }
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.advance(0)
            assert.is_true(ns.BuffMode.IsOn(), "you're still missing Mark of the Wild")
            scroll()
            assert.is_false(ns.BuffMode.IsOn())
        end)
    end)

    describe("what it won't do (black)", function()
        local function only(reason)
            local offer, why, settled = ns.GroupBuffs.Next()
            assert.is_nil(offer)
            assert.are.equal(reason, why)
            return settled
        end

        it("doesn't buff you when you're dead, says so, and isn't settled", function()
            party({ "Ann-Vale" })
            wearEverything(wow.state.units.party1)
            wow.state.units.player.dead = true
            assert.is_false(only("You: you're dead"))
            wow.state.units.player.dead = nil
            assert.are.equal("me: Mark of the Wild", armed())
        end)

        it("doesn't cast when your own buffs can't be read, and doesn't call you done", function()
            party({ "Ann-Vale" })
            wearEverything(wow.state.units.party1)
            wow.state.aurasRestricted = true
            ns.BuffButton.Refresh()
            assert.is_nil(macro())
            assert.is_false(select(3, ns.GroupBuffs.Next()), "not settled while buffs can't be read")
            wow.state.aurasRestricted = nil
        end)

        it("doesn't cast when a buff of yours is a secret value, and says so", function()
            party({ "Ann-Vale" })
            wearEverything(wow.state.units.party1)
            wow.state.playerAuras = { wow.secret({ spellId = MOTW, isHelpful = true }) }
            ns.BuffButton.Refresh()
            assert.is_nil(macro())
            assert.are.equal("You: can't see your buffs", select(2, ns.GroupBuffs.Next()))
            wow.state.playerAuras = {}
            ns.BuffButton.Refresh()
            assert.are.equal("me: Mark of the Wild", armed())
        end)

        it("doesn't cast when your own name can't be read", function()
            party({ "Ann-Vale" })
            wearEverything(wow.state.units.party1)
            wow.state.units.player.secrets = { name = true }
            ns.BuffButton.Refresh()
            assert.is_nil(macro())
            assert.is_false(only("You: your name can't be read"))
        end)

        it("doesn't offer a buff a group version on you already covers (Gift of the Wild)", function()
            party({ "Ann-Vale" })
            wearEverything(wow.state.units.party1)
            wow.gainBuff({ spellId = 21850, sourceUnit = "party1" })
            wow.gainBuff({ spellId = THORNS_1, sourceUnit = "player" })
            ns.BuffButton.Refresh()
            assert.is_nil(macro())
            assert.are.equal("everyone in your group has your buffs", select(2, ns.GroupBuffs.Next()))
        end)

        it("never offers a buff only for yourself on you (a warrior's Battle Shout)", function()
            boot({ known = { [6673] = true }, class = "WARRIOR" })
            party({ "Ann-Vale" })
            ns.BuffButton.Refresh()
            assert.is_nil(macro())
            assert.are.equal("everyone in your group has your buffs", select(2, ns.GroupBuffs.Next()))
        end)

        it("says it in your words when your own role can't be read for a tanks-only rule", function()
            party({ "Ann-Vale" })
            wearEverything(wow.state.units.party1)
            ns.db.buffBack.whoGets.motw = { rule = "tanks" }
            wow.gainBuff({ spellId = THORNS_1, sourceUnit = "player" })
            wow.state.units.player.secrets = { role = true, mainTank = true }
            ns.BuffButton.Refresh()
            assert.is_nil(macro())
            assert.are.equal("You: can't tell if you're a tank", select(2, ns.GroupBuffs.Next()))
            assert.is_false(select(3, ns.GroupBuffs.Next()))
        end)

        it("says in debug, once, why you're left out", function()
            ns.db.debug = true
            party({ "Ann-Vale" })
            wearEverything(wow.state.units.party1)
            wow.state.units.player.dead = true
            for _ = 1, 3 do ns.BuffButton.Refresh() end
            local lines = 0
            for _, line in ipairs(ns.db.diagLog) do
                if line:find("not buffing you: you're dead", 1, true) then lines = lines + 1 end
            end
            assert.are.equal(1, lines)
        end)

        it("makes a macro only from a safe spell name", function()
            assert.is_nil(ns.BuffButton.BuildCastMacro("Me", "Bad;Spell", false, true))
            assert.is_nil(ns.BuffButton.BuildCastMacro("Me", "Bad\n/script x()", false, true))
            assert.is_nil(ns.BuffButton.BuildCastMacro("Me", string.rep("a", 300), false, true))
            assert.are.equal("/cast [@player,nodead] Thorns", ns.BuffButton.BuildCastMacro("Me", "Thorns", true, true))
        end)

        it("never casts without a press", function()
            party({ "Ann-Vale" })
            wearEverything(wow.state.units.party1)
            wow.advance(60)
            assert.are.equal(0, #wow.casts)
        end)
    end)

    describe("chaos (red tests)", function()
        it("with you in and out of groups, dying and changing auras, never errors and casts on you only when you may be", function()
            local everyone = { "Ann-Vale", "Cid-Rock", "Dot-Fern" }
            local selfCasts = 0
            for _, seed in ipairs({ 3, 41, 99, 512 }) do
                random.seed(seed)
                boot()
                local function roster()
                    local names = {}
                    for _, n in ipairs(everyone) do
                        if random.random() < 0.5 then names[#names + 1] = n end
                    end
                    local kind = ({ "party", "raid", nil })[random.random(3)]
                    if #names == 0 then kind = nil end -- a group of one disbands
                    wow.setGroup(kind, kind and names or {})
                    if kind == "raid" and random.random() < 0.5 then
                        wow.addUnit("raid" .. (#names + 1), wow.state.units.player)
                    end
                    wow.fire("GROUP_ROSTER_UPDATE")
                end
                local actions = {
                    roster,
                    function() wow.state.units.player.dead = random.random() < 0.3 end,
                    function() wow.state.units.player.secrets = random.random() < 0.2 and { name = true } or nil end,
                    function() wow.state.playerAuras = {} end,
                    function() wow.gainBuff({ spellId = MOTW, sourceUnit = "player" }) end,
                    function() wow.gainBuff({ spellId = THORNS_1, sourceUnit = "player" }) end,
                    function() wow.state.aurasRestricted = random.random() < 0.2 end,
                    function() scroll() end,
                    function() wow.press(button, random.random() < 0.8 and "LeftButton" or "RightButton") end,
                    function() if wow.state.inCombat then wow.leaveCombat() else wow.enterCombat() end end,
                    function() slash(random.random() < 0.8 and "buffmode on" or "buffmode off") end,
                    function() wow.advance(random.random() * 8) end,
                }
                for step = 1, 500 do
                    local before = #wow.casts
                    local wasDead = wow.state.units.player.dead
                    local wasHidden = wow.state.units.player.secrets
                    -- Worked out from the client's own state before the step.
                    local grouped = wow.state.groupType ~= nil
                    local wears = {}
                    for _, aura in ipairs(wow.state.playerAuras) do
                        if type(aura) == "table" and wow.SPELL_NAMES[aura.spellId] then
                            wears[wow.SPELL_NAMES[aura.spellId]] = true
                        end
                    end
                    actions[random.random(#actions)]()
                    for i = before + 1, #wow.casts do
                        local cast = wow.casts[i]
                        if cast.target == "Me" then
                            local where = ("seed %d, step %d: %s on you"):format(seed, step, cast.spell)
                            assert.is_falsy(wasDead, where .. ", dead")
                            assert.is_falsy(wasHidden, where .. ", name unreadable")
                            assert.is_truthy(grouped, where .. ", outside a group")
                            assert.is_falsy(wears[cast.spell], where .. ", already on you")
                            selfCasts = selfCasts + 1
                        end
                    end
                end
                assert.are.same({}, wow.errors, "seed " .. seed)
            end
            assert.is_true(selfCasts > 5, "casts on you: " .. selfCasts)
        end)
    end)
end)
