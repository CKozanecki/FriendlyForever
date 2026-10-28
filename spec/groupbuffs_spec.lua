-- Spec: #30, #76
-- Buff mode buffs group members missing your buffs, one per press, with the
-- same safety rules as buff back.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local MOTW, MOTW_1, THORNS_1 = 9885, 1126, 467
local INTELLECT = 10157

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

describe("Buffing your group in buff mode", function()
    local ns, button

    -- A druid who knows Mark of the Wild and Thorns, in buff mode.
    local function boot(opts)
        opts = opts or {}
        ns = wow.boot({ db = opts.db, before = function(state)
            state.class = "DRUID"
            state.knownSpells = opts.known or { [MOTW_1] = true, [MOTW] = true, [THORNS_1] = true }
        end })
        button = ns.BuffButton.Frame()
        if opts.buffMode ~= false then slash("buffmode on") end
    end

    local function macro() return button:GetAttribute(ns.BuffButton.SECURE_ATTRIBUTE.leftButtonMacroText) end

    -- What the armed button casts, and on whom.
    local function armed()
        local text = macro()
        if not text then return nil end
        return text:match("/targetexact ([^\n]+)") .. ": " .. text:match("/cast %[help,nodead%] ([^\n]+)")
    end

    -- The unit token showing this player id, if any.
    local function tokenOf(id)
        for token, u in pairs(wow.state.units) do
            if u.id == id and token ~= "target" then return token end
        end
    end

    -- Scroll once, and let the buff show on whoever it reached (the game
    -- shows a new aura a moment after the cast).
    local function scroll()
        local before = #wow.casts
        wow.pressKey("MOUSEWHEELUP")
        local cast = wow.casts[before + 1]
        if cast and not cast.failed then
            local u = wow.state.units[tokenOf(cast.target)]
            if u then
                u.auras = u.auras or {}
                u.auras[#u.auras + 1] = cast.id
                u.auraSources = u.auraSources or {}
                u.auraSources[#u.auras] = "player"
            end
        end
        return cast
    end

    local function party(names)
        wow.setGroup("party", names)
        wow.fire("GROUP_ROSTER_UPDATE")
        wow.advance(0)
    end

    before_each(function() boot() end)

    describe("whom it buffs", function()
        it("buffs each party member missing a buff, one per press, until everyone has it", function()
            party({ "Ann-Vale", "Cid-Rock", "Dot-Fern" })
            assert.are.equal("Ann Vale: Mark of the Wild", armed())
            assert.are.equal("missing your Mark of the Wild", button.subtitle:GetText())
            local order = {}
            for _ = 1, 6 do
                local cast = scroll()
                order[#order + 1] = cast.target .. " " .. cast.spell
            end
            assert.are.same({
                "Ann-Vale Mark of the Wild", "Cid-Rock Mark of the Wild", "Dot-Fern Mark of the Wild",
                "Ann-Vale Thorns", "Cid-Rock Thorns", "Dot-Fern Thorns",
            }, order, "your first buff to everyone, then the next")
            assert.is_nil(macro())
            assert.are.equal("everyone in your group has your buffs", button.subtitle:GetText())
            scroll()
            assert.are.equal(6, #wow.casts, "nothing more to cast")
        end)

        it("buffs raid members too, and never you in your own raid slot", function()
            wow.setGroup("raid", { "Ann-Vale", "Cid-Rock" })
            wow.addUnit("raid3", wow.state.units.player) -- the game gives you a raid slot
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.advance(0)
            local targets = {}
            for _ = 1, 6 do
                local cast = scroll()
                if cast then targets[#targets + 1] = cast.target end
            end
            assert.are.same({ "Ann-Vale", "Cid-Rock", "Ann-Vale", "Cid-Rock" }, targets)
        end)

        it("doesn't offer the same buff again while it's still showing up on them", function()
            party({ "Ann-Vale", "Cid-Rock" })
            wow.pressKey("MOUSEWHEELUP") -- the aura doesn't show yet
            assert.are.equal("Cid Rock: Mark of the Wild", armed())
            wow.pressKey("MOUSEWHEELUP")
            wow.advance(ns.GroupBuffs.JUST_GIVEN_SECONDS + 1)
            assert.are.equal("Ann Vale: Mark of the Wild", armed(), "still missing after a while: offered again")
        end)

        it("returns favours owed to strangers first", function()
            party({ "Ann-Vale" })
            wow.addUnit("nameplate1", { name = "Bob", surname = "Stone", class = "WARRIOR", id = "Bob-Stone" })
            wow.gainBuff({ sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = INTELLECT })
            assert.are.equal("Bob Stone: Mark of the Wild", armed())
            scroll()
            assert.are.equal("Ann Vale: Mark of the Wild", armed())
        end)

        it("never offers a buff you cast on yourself (a warrior's Battle Shout)", function()
            boot({ known = { [6673] = true } })
            wow.state.class = "WARRIOR"
            ns.BuffData.SpellsChanged()
            party({ "Ann-Vale" })
            ns.BuffButton.Refresh()
            assert.is_nil(macro())
            assert.are.equal("everyone in your group has your buffs", button.subtitle:GetText())
        end)

        it("gives a paladin's members one Blessing each, never replacing yours", function()
            local KINGS, MIGHT_1, WISDOM_1 = 20217, 19740, 19742
            boot({ known = { [KINGS] = true, [MIGHT_1] = true, [WISDOM_1] = true } })
            wow.state.class = "PALADIN"
            ns.BuffData.SpellsChanged()
            wow.setGroup("party", { "Ann-Vale", "Cid-Rock" })
            wow.state.units.party1.class = "WARRIOR"
            wow.state.units.party2.class = "MAGE"
            ns.db.buffBack.buffOrder = { "might", "wisdom", "kings" }
            ns.BuffButton.Refresh()
            local given = {}
            for _ = 1, 6 do
                local cast = scroll()
                if cast then given[#given + 1] = cast.target .. " " .. cast.spell end
            end
            -- Might comes first in your order: each gets Might, and then no
            -- other Blessing, which would replace it.
            assert.are.same({ "Ann-Vale Blessing of Might", "Cid-Rock Blessing of Might" }, given)
            assert.are.equal("everyone in your group has your buffs", button.subtitle:GetText())
        end)

        it("still gives your Blessing to someone wearing another paladin's", function()
            local KINGS, MIGHT_1 = 20217, 19740
            boot({ known = { [KINGS] = true, [MIGHT_1] = true } })
            wow.state.class = "PALADIN"
            ns.BuffData.SpellsChanged()
            wow.setGroup("party", { "Ann-Vale", "Gus-Hill" })
            wow.state.units.party1.auras = { MIGHT_1 }
            wow.state.units.party1.auraSources = { "party2" } -- Gus's Might, not yours
            ns.BuffButton.Refresh()
            assert.are.equal("Ann Vale: Blessing of Kings", armed())
            wow.state.units.party1.auraSources = { nil }
            ns.BuffButton.Refresh()
            assert.are.equal("Gus Hill: Blessing of Kings", armed(), "whose Blessing Ann has can't be told: left alone")
        end)

        it("only in buff mode", function()
            boot({ buffMode = false })
            party({ "Ann-Vale" })
            assert.is_nil(macro())
            assert.is_false(button:IsShown())
            slash("buffmode on")
            assert.are.equal("Ann Vale: Mark of the Wild", armed())
            slash("buffmode off")
            assert.is_nil(macro())
        end)

        it("follows your buff order and never-offer marks, and skips buffs their class can't use", function()
            ns.db.buffBack.buffOrder = { "thorns", "motw" }
            party({ "Ann-Vale" })
            ns.BuffButton.Refresh()
            assert.are.equal("Ann Vale: Thorns", armed())
            ns.db.buffBack.neverOffer = { thorns = true }
            ns.BuffButton.Refresh()
            assert.are.equal("Ann Vale: Mark of the Wild", armed())

            boot({ known = { [10157] = true } }) -- a mage's Arcane Intellect, to a warrior
            wow.state.class = "MAGE"
            ns.BuffData.SpellsChanged()
            wow.setGroup("party", { "Ann-Vale" })
            wow.state.units.party1.class = "WARRIOR"
            ns.BuffButton.Refresh()
            assert.is_nil(macro())
            assert.are.equal("everyone in your group has your buffs", button.subtitle:GetText())
        end)
    end)

    describe("presses", function()
        it("says what it gave, never a line, and never thanks", function()
            ns.db.buffBack.sayLine = true
            ns.db.buffBack.messages = { "For you, {name}!" }
            party({ "Ann-Vale" })
            scroll()
            assert.are.equal("Gave Mark of the Wild to Ann Vale.", button.result:GetText())
            wow.advance(0)
            wow.keyDown()
            assert.are.same({}, wow.sentTo("SAY"))
            assert.are.equal(0, #ns.db.ledger.entries, "a group buff is no favour")
        end)

        it("a refusal about you (the global cooldown, mana) moves no one back", function()
            party({ "Ann-Vale", "Cid-Rock" })
            for _, why in ipairs({ "Spell is not ready yet.", "Not enough mana", "Can't do that while stunned" }) do
                wow.state.castFailures["Ann-Vale"] = why
                wow.pressKey("MOUSEWHEELUP")
                assert.are.equal("Ann Vale: Mark of the Wild", armed(), why)
            end
            wow.state.castFailures["Ann-Vale"] = nil
            scroll()
            assert.are.equal("Cid Rock: Mark of the Wild", armed())
        end)

        it("knows the game's own text for target refusals", function()
            local is = ns.GroupBuffs.IsTargetRefusal
            assert.is_true(is("Out of range."))
            assert.is_true(is("Target not in line of sight"))
            assert.is_true(is("|cffff0000Invalid target|r"))
            assert.is_false(is("Spell is not ready yet."))
            assert.is_false(is(nil))
            assert.is_false(is(wow.secret("Out of range.")))
            finally(function() _G.SPELL_FAILED_LINE_OF_SIGHT = nil end)
            _G.SPELL_FAILED_LINE_OF_SIGHT = "Ziel nicht im Sichtfeld"
            assert.is_true(is("Ziel nicht im Sichtfeld"), "a translated client's own string")
        end)

        it("a press that casts nothing (a mind-controlled member) holds that member back too", function()
            party({ "Ann-Vale", "Cid-Rock" })
            wow.state.units.party1.hostile = true -- [help] finds no friend: nothing is cast
            wow.pressKey("MOUSEWHEELUP")
            assert.are.equal(0, #wow.casts)
            wow.advance(ns.BuffButton.ANSWER_WINDOW_SECONDS + 0.5)
            assert.is_truthy(button.result:GetText():find("No answer", 1, true))
            assert.are.equal("Cid Rock: Mark of the Wild", armed())
        end)

        it("right-click skips a member for a while, and the button says so", function()
            party({ "Ann-Vale", "Cid-Rock" })
            wow.press(button, "RightButton")
            assert.are.equal("Skipping Ann Vale for 5 minutes.", button.result:GetText())
            assert.are.equal("Cid Rock: Mark of the Wild", armed())
            scroll()
            scroll()
            assert.is_nil(macro())
            assert.are.equal("Ann Vale: skipped for now (you right-clicked them)", button.subtitle:GetText(),
                "not 'everyone has your buffs'")
            wow.advance(ns.GroupBuffs.SKIP_SECONDS + 1)
            assert.are.equal("Ann Vale: Mark of the Wild", armed())
        end)

        it("a refused cast is reported, and the next press goes to the next member", function()
            party({ "Ann-Vale", "Cid-Rock" })
            wow.state.castFailures["Ann-Vale"] = "Target not in line of sight"
            wow.pressKey("MOUSEWHEELUP")
            assert.is_truthy(button.result:GetText():find("Target not in line of sight", 1, true))
            assert.are.equal("Cid Rock: Mark of the Wild", armed())
            scroll()
            scroll() -- Cid's Thorns
            assert.is_nil(macro(), "Ann waits a moment")
            assert.are.equal("Ann Vale: the game refused your last cast to them", button.subtitle:GetText())
            wow.state.castFailures["Ann-Vale"] = nil
            wow.advance(ns.GroupBuffs.HELD_BACK_SECONDS + 1)
            assert.are.equal("Ann Vale: Mark of the Wild", armed(), "then back on the list")
        end)



    end)

    describe("members it can't buff (black)", function()
        local function only(spec, why)
            boot()
            wow.setGroup("party", { "Ann-Vale" })
            for k, v in pairs(spec) do wow.state.units.party1[k] = v end
            ns.BuffButton.Refresh()
            assert.is_nil(macro(), why)
            assert.are.equal(why, button.subtitle:GetText())
        end

        it("skips the dead, the offline, and anyone out of range or out of sight, saying why", function()
            only({ dead = true }, "Ann Vale: dead")
            only({ offline = true }, "Ann Vale: offline")
            only({ outOfRange = true }, "Ann Vale: out of range")
            only({ hidden = true }, "Ann Vale: out of sight")
        end)

        it("skips members the spell can't reach, though they're in the group's range", function()
            party({ "Ann-Vale", "Cid-Rock" })
            wow.state.units.party1.outOfSpellRange = true
            ns.BuffButton.Refresh()
            assert.are.equal("Cid Rock: Mark of the Wild", armed())
            scroll()
            scroll()
            assert.is_nil(macro())
            assert.are.equal("Ann Vale: out of range", button.subtitle:GetText())
            wow.state.units.party1.outOfSpellRange = nil
            wow.state.units.party1.spellRangeUnknown = true
            ns.BuffButton.Refresh()
            assert.are.equal("Ann Vale: Mark of the Wild", armed(), "the game won't say: try (the cast tells)")
        end)

        it("buffs someone whose range the game can't tell (the cast says if they're too far)", function()
            only({ rangeUnknown = true, auras = { MOTW, THORNS_1 } }, "everyone in your group has your buffs")
            wow.state.units.party1.auras = nil
            ns.BuffButton.Refresh()
            assert.are.equal("Ann Vale: Mark of the Wild", armed())
        end)

        it("skips members flagged for PvP unless you are, and members whose flag can't be read", function()
            only({ pvp = true }, "Ann Vale: flagged for PvP and you aren't")
            only({ secrets = { pvp = true } }, "Ann Vale: can't see whether they're flagged for PvP")
            wow.state.pvp = true
            wow.state.units.party1.pvp = true
            wow.state.units.party1.secrets = nil
            ns.BuffButton.Refresh()
            assert.are.equal("Ann Vale: Mark of the Wild", armed(), "you're flagged too: no harm")
        end)

        it("skips members whose name or buffs can't be read", function()
            only({ secrets = { name = true } }, "a group member's name can't be read")
            only({ secrets = { auras = true }, auras = { 1459 } }, "Ann Vale: can't see their buffs")
        end)

        it("moves on to the next member past one it can't buff", function()
            party({ "Ann-Vale", "Cid-Rock" })
            wow.state.units.party1.dead = true
            ns.BuffButton.Refresh()
            assert.are.equal("Cid Rock: Mark of the Wild", armed())
        end)

        it("is empty in a fight and buffs again after", function()
            party({ "Ann-Vale" })
            wow.enterCombat()
            assert.is_nil(macro())
            wow.leaveCombat()
            assert.are.equal("Ann Vale: Mark of the Wild", armed())
            assert.are.same({}, wow.errors)
        end)
    end)

    describe("chaos (red tests)", function()
        it("with a changing roster, never casts outside the group, on the dead, on the flagged, or on you", function()
            local everyone = { "Ann-Vale", "Cid-Rock", "Dot-Fern", "Eve-Moss", "Fay-Reed", "Gus-Hill" }
            local casts = 0
            for _, seed in ipairs({ 5, 30, 77, 300, 2026 }) do
                random.seed(seed)
                boot()
                local members = {}
                local function roster()
                    local names = {}
                    for _, n in ipairs(everyone) do
                        if random.random() < 0.5 then names[#names + 1] = n end
                    end
                    local kind = ({ "party", "raid", nil })[random.random(3)]
                    if kind == "party" then while #names > 4 do table.remove(names) end end
                    wow.setGroup(kind, kind and names or {})
                    if kind == "raid" and random.random() < 0.5 then
                        wow.addUnit("raid" .. (#names + 1), wow.state.units.player)
                    end
                    local left = members
                    members = {}
                    for _, n in ipairs(kind and names or {}) do members[n] = true end
                    -- Whoever left is still nearby, targetable by name: a stale
                    -- choice would land on them, outside the group.
                    local i = 0
                    for n in pairs(left) do
                        if not members[n] then
                            i = i + 1
                            local first, last = n:match("^([^%-]+)%-(.+)$")
                            wow.addUnit("nameplate" .. i, { name = first, surname = last, id = n })
                        end
                    end
                    wow.fire("GROUP_ROSTER_UPDATE")
                end
                local function someone()
                    local tokens = {}
                    for token in pairs(wow.state.units) do
                        if token:find("^party") or token:find("^raid") then tokens[#tokens + 1] = token end
                    end
                    table.sort(tokens)
                    return wow.state.units[tokens[random.random(math.max(#tokens, 1))] or "none"]
                end
                local actions = {
                    roster,
                    function() local u = someone(); if u and u.id ~= "Me" then u.dead = random.random() < 0.3 end end,
                    function() local u = someone(); if u and u.id ~= "Me" then u.pvp = random.random() < 0.3 end end,
                    function() local u = someone(); if u and u.id ~= "Me" then u.outOfRange = random.random() < 0.3 end end,
                    function() local u = someone(); if u and u.id ~= "Me" then u.offline = random.random() < 0.2 end end,
                    function() local u = someone(); if u and u.id ~= "Me" then u.auras = nil end end,
                    function() wow.state.pvp = random.random() < 0.2 end,
                    function() scroll() end,
                    function() wow.press(button, random.random() < 0.8 and "LeftButton" or "RightButton") end,
                    function() if wow.state.inCombat then wow.leaveCombat() else wow.enterCombat() end end,
                    function() slash(random.random() < 0.8 and "buffmode on" or "buffmode off") end,
                    function() wow.state.castLatency = ({ 0, 0, 0.5 })[random.random(3)] end,
                    function() wow.advance(random.random() * 8) end,
                }
                for step = 1, 600 do
                    local before = #wow.casts
                    -- Who may be buffed, as the game stands just before the action.
                    local alive = {}
                    for token, u in pairs(wow.state.units) do
                        if (token:find("^party") or token:find("^raid")) and members[u.id] then
                            alive[u.id] = { dead = u.dead, pvp = u.pvp }
                        end
                    end
                    local iAmFlagged = wow.state.pvp
                    actions[random.random(#actions)]()
                    for i = before + 1, #wow.casts do
                        local cast = wow.casts[i]
                        local where = ("seed %d, step %d: %s on %s"):format(seed, step, cast.spell, cast.target)
                        local was = alive[cast.target]
                        assert.is_truthy(was, where .. ", not in the group")
                        assert.are_not.equal("Me", cast.target, where)
                        assert.is_falsy(cast.targetDead or was.dead, where .. ", dead")
                        assert.is_true(iAmFlagged or not was.pvp, where .. ", flagged when you weren't")
                        casts = casts + 1
                    end
                    assert.are.same({}, wow.flaggedBy, ("seed %d, step %d: flagged for PvP"):format(seed, step))
                end
                assert.are.same({}, wow.errors, "seed " .. seed)
            end
            assert.is_true(casts > 30, "casts: " .. casts)
        end)
    end)
end)
