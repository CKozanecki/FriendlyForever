-- Spec: #138
-- Buff receipts: when your buff lands on a player outside your group, your
-- copy whispers theirs a hidden RECEIPT, used only to name the caster of a
-- buff whose caster the game wouldn't name.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local FORT, SPIRIT = 10938, 27841
local MOTW, THORNS = 9885, 9910

local function count(ns, key)
    return ns.Diag.Counters()[key] or 0
end

local function receiptsIn(list)
    local out = {}
    for _, m in ipairs(list) do
        if m.text:find(";RECEIPT;", 1, true) then out[#out + 1] = m end
    end
    return out
end

describe("Buff receipts (#138)", function()
    local a, b, net

    local ANN = { name = "Ann", surname = "Vale", class = "PRIEST", id = "Ann-Vale" }
    local BO = { name = "Bo", surname = "Lake", class = "DRUID", id = "Bo-Lake" }

    -- Ann Vale, a priest, and Bo Lake, a druid, out in the world. Neither
    -- shows the other under any unit token, so a buff's caster can't be
    -- read. Thank-yous are whispered. opts.db: extra buff settings for both;
    -- opts.before(state, who): more setup for "a" or "b".
    local function pair(opts)
        opts = opts or {}
        local function setup(who, class, known)
            return function(state)
                state.class, state.knownSpells = class, known
                if opts.before then opts.before(state, who) end
            end
        end
        local function db()
            local buff = { thankStyle = "whisper", messages = { "Thanks {name}: {buff}" } }
            for k, v in pairs(opts.db or {}) do buff[k] = v end
            return { buff = buff, buffBack = { enabled = true } }
        end
        a = wow.newClient({ name = "Ann", surname = "Vale", db = db(),
            before = setup("a", "PRIEST", { [FORT] = true, [SPIRIT] = true }) })
        b = wow.newClient({ name = "Bo", surname = "Lake", db = db(),
            before = setup("b", "DRUID", { [MOTW] = true, [THORNS] = true }) })
        net = wow.network({ a, b })
    end

    -- The buff reaches the other client, then the addon messages.
    local function settle()
        wow.deliverBuffs(net)
        wow.deliver(net)
    end

    -- Past the receipt wait and the thank-you delay.
    local function afterThanks()
        wow.use(b)
        wow.advanceAll(net, b.ns.Receipts.WAIT + b.ns.db.buff.delay + 0.5, 0.25)
    end

    -- The client targets this unit and casts a spell by hand. The target is
    -- dropped again, so the other side still can't see the caster.
    local function handCast(client, unit, spell)
        wow.use(client)
        wow.addUnit("target", unit)
        wow.runMacro("/cast " .. spell)
        wow.state.units.target = nil
        settle()
    end

    local function whispers(client)
        wow.use(client)
        local out = {}
        for _, m in ipairs(wow.sent) do
            if m.channel == "WHISPER" then out[#out + 1] = { target = m.target, text = m.text } end
        end
        return out
    end

    local function noErrors()
        for _, c in ipairs({ a, b }) do
            wow.use(c)
            assert.are.same({}, wow.errors)
            assert.are.equal(0, count(c.ns, "luaErrors"))
        end
    end

    describe("A buffs B, whose aura shows no readable caster (white)", function()
        it("B's copy thanks A by name and can offer A's buff back", function()
            pair()
            handCast(a, BO, "Power Word: Fortitude")
            wow.use(a)
            assert.are.equal(1, #receiptsIn(wow.addonSent), "one receipt for the cast")
            assert.are.equal("1;RECEIPT;Ann-Vale;fortitude;" .. a.ns.VERSION, receiptsIn(wow.addonSent)[1].text,
                "only the buff's key and our version")
            afterThanks()
            assert.are.same({ { target = "Ann-Vale", text = "Thanks Ann: Power Word: Fortitude" } }, whispers(b))
            wow.use(b)
            assert.are.equal(1, b.ns.Offers.Count(), "B owes A a buff back")
            -- Ann walks into view: the button offers her Bo's buff.
            wow.addUnit("nameplate1", ANN)
            local offer = b.ns.Offers.Current()
            assert.are.equal("Ann-Vale", offer and offer.name)
            noErrors()
        end)

        it("B returns it with the button, and Ann's copy, which can't see Bo either, thanks Bo by name", function()
            pair()
            handCast(a, BO, "Power Word: Fortitude")
            afterThanks()
            wow.use(b)
            wow.addUnit("nameplate1", ANN)
            b.ns.BuffButton.Refresh()
            wow.press(b.ns.BuffButton.Frame())
            wow.state.units.nameplate1, wow.state.units.target = nil, nil
            settle()
            assert.are.equal(1, #receiptsIn(wow.addonSent), "the button's cast sends one receipt too")
            assert.are.equal(0, b.ns.Offers.Count())
            wow.use(a)
            wow.advanceAll(net, a.ns.Receipts.WAIT + a.ns.db.buff.delay + 0.5, 0.25)
            assert.are.same({ { target = "Bo-Lake", text = "Thanks Bo: Mark of the Wild" } }, whispers(a))
            wow.use(a)
            assert.are.equal(0, a.ns.Offers.Count(), "Bo's buff answered Ann's: nothing owed back")
            noErrors()
        end)

        it("works when the game spells the sender 'First Surname'", function()
            pair({ before = function(state) state.addonSenderForm = "space" end })
            handCast(a, BO, "Power Word: Fortitude")
            afterThanks()
            assert.are.same({ { target = "Ann-Vale", text = "Thanks Ann: Power Word: Fortitude" } }, whispers(b))
        end)

        it("a buff still waiting for its receipt keeps a thanked exchange open: one thank-you", function()
            -- Bo sees Ann for her first buff, which is thanked; she walks out
            -- of view and buffs again just before the exchange would end.
            -- No repeat cooldown, so only the exchange can stop a second one.
            pair({ db = { repeatCooldown = 0 },
                before = function(_, who) if who == "b" then wow.addUnit("nameplate1", ANN) end end })
            handCast(a, BO, "Power Word: Fortitude")
            -- Bo's armed button holds the thank-you (Ann's copy sent its
            -- plan) until MAX_DELAY, when it goes and the exchange, quiet
            -- for longer than GAP, ends. Ann's second buff lands a moment
            -- before that, out of Bo's view, and is named after it.
            wow.advanceAll(net, b.ns.Exchange.MAX_DELAY - 1, 0.25)
            assert.are.equal(0, #whispers(b))
            wow.use(b)
            wow.state.units.nameplate1 = nil
            handCast(a, BO, "Divine Spirit")
            wow.advanceAll(net, b.ns.Exchange.MAX_DELAY + 1, 0.25)
            assert.are.equal(1, #whispers(b), "the second buff joins the exchange already thanked")
            wow.use(b)
            assert.are.equal(1, count(b.ns, "receiptsUsed"), "the receipt named Ann")
        end)

        it("two buffs from one caster a moment apart join one thank-you", function()
            pair()
            handCast(a, BO, "Power Word: Fortitude")
            wow.advanceAll(net, 1, 0.25)
            handCast(a, BO, "Divine Spirit")
            afterThanks()
            assert.are.same({ { target = "Ann-Vale", text = "Thanks Ann: Power Word: Fortitude and Divine Spirit" } },
                whispers(b))
        end)

        it("a receipt that comes a moment before its buff still names the caster", function()
            pair()
            wow.use(b)
            wow.fire("CHAT_MSG_ADDON", "FriendlyFvr", "1;RECEIPT;Ann-Vale;fortitude;0.8.0", "WHISPER", "Ann-Vale",
                "", 0, 0, "", 0)
            wow.advance(1)
            wow.gainBuff({ name = "Power Word: Fortitude", spellId = FORT })
            afterThanks()
            assert.are.same({ { target = "Ann-Vale", text = "Thanks Ann: Power Word: Fortitude" } }, whispers(b))
        end)
    end)

    describe("a buff whose caster is readable (white)", function()
        -- The same story twice, Bo seeing Ann on a nameplate: once with the
        -- receipt delivered, once with it lost. The results must match.
        local function run(loseReceipts)
            pair({ before = function(_, who) if who == "b" then wow.addUnit("nameplate1", ANN) end end })
            if loseReceipts then
                net.lose = function(msg) return msg.text:find(";RECEIPT;", 1, true) ~= nil end
            end
            handCast(a, BO, "Power Word: Fortitude")
            -- Bo's armed button holds the thank-you, at most Exchange.MAX_DELAY.
            wow.advanceAll(net, b.ns.Exchange.MAX_DELAY + 1, 0.5)
            wow.use(b)
            local offer = b.ns.Offers.Current()
            return { thanks = whispers(b), owed = b.ns.Offers.Count(), offer = offer and offer.name,
                ledger = b.ns.Ledger.Lines() }
        end

        it("its receipt names no one else: a stranger's unnamed buff of that key just after is 'friend'", function()
            pair({ before = function(_, who) if who == "b" then wow.addUnit("nameplate1", ANN) end end })
            handCast(a, BO, "Power Word: Fortitude")
            wow.advanceAll(net, 4, 0.25)
            -- Cid, who has no addon and no unit on Bo's screen, buffs Bo too.
            wow.use(b)
            wow.gainBuff({ name = "Power Word: Fortitude", spellId = FORT })
            wow.advanceAll(net, b.ns.Exchange.MAX_DELAY + 1, 0.25)
            wow.use(b)
            wow.keyDown()
            assert.are.same({ { target = "Ann-Vale", text = "Thanks Ann: Power Word: Fortitude" } }, whispers(b))
            wow.use(b)
            assert.are.equal(1, #wow.sentTo("SAY"), "Cid's buff is thanked as 'friend'")
            assert.are.equal(0, count(b.ns, "receiptsUsed"))
        end)

        it("its receipt names no one else when it comes before the buff, either", function()
            local ns = wow.boot({ db = { buff = { thankStyle = "whisper", messages = { "Thanks {name}" } } } })
            wow.addUnit("nameplate1", ANN)
            wow.fire("CHAT_MSG_ADDON", "FriendlyFvr", "1;RECEIPT;Ann-Vale;fortitude;?", "WHISPER", "Ann-Vale",
                "", 0, 0, "", 0)
            wow.gainBuff({ sourceUnit = "nameplate1", name = "Power Word: Fortitude", spellId = FORT })
            wow.advance(1)
            wow.gainBuff({ name = "Power Word: Fortitude", spellId = FORT })
            wow.advance(30)
            wow.keyDown()
            assert.are.same({ "Thanks Ann" }, wow.sentTo("WHISPER"))
            assert.are.equal(1, #wow.sentTo("SAY"), "the second buff is thanked as 'friend'")
            assert.are.equal(0, count(ns, "receiptsUsed"))
        end)

        -- Bo alone sees `steps` happen: { "named", who, spell }, a buff whose
        -- caster the game names; { "unnamed", spell }, one it doesn't;
        -- { "receipt", who, key }; or a number of seconds passing.
        local function story(steps)
            local ns = wow.boot({ db = { buff = { thankStyle = "whisper", repeatCooldown = 0,
                messages = { "Thanks {name}" } } } })
            local ids = { fortitude = FORT, spirit = SPIRIT }
            for _, step in ipairs(steps) do
                if type(step) == "number" then
                    wow.advance(step)
                elseif step[1] == "named" then
                    wow.addUnit("nameplate1", { name = step[2]:match("^(%a+)"), surname = step[2]:match("-(%a+)$"),
                        id = step[2] })
                    wow.gainBuff({ sourceUnit = "nameplate1", name = step[3], spellId = ids[step[3]] })
                    wow.state.units.nameplate1 = nil
                elseif step[1] == "unnamed" then
                    wow.gainBuff({ name = step[2], spellId = ids[step[2]] })
                else
                    wow.fire("CHAT_MSG_ADDON", "FriendlyFvr", "1;RECEIPT;" .. step[2] .. ";" .. step[3] .. ";?",
                        "WHISPER", step[2], "", 0, 0, "", 0)
                end
            end
            -- A /say "friend" waits for a key press, and at most SAY_MAX_AGE.
            wow.advance(ns.Receipts.WAIT + ns.db.buff.delay + 0.5)
            wow.keyDown()
            wow.advance(40)
            wow.keyDown()
            assert.are.same({}, wow.errors)
            return count(ns, "receiptsUsed"), #wow.sentTo("SAY")
        end

        it("with no receipt, an unnamed buff is thanked as 'friend' (the count is live)", function()
            local used, friends = story({ { "named", "Ann-Vale", "fortitude" }, 3, { "unnamed", "spirit" } })
            assert.are.equal(0, used)
            assert.are.equal(1, friends)
        end)
        it("a stale receipt isn't what a named buff uses up: its own receipt still is", function()
            local used, friends = story({ { "receipt", "Ann-Vale", "fortitude" }, 10,
                { "named", "Ann-Vale", "fortitude" }, { "receipt", "Ann-Vale", "fortitude" }, 0.5,
                { "unnamed", "fortitude" } })
            assert.are.equal(0, used, "the stranger's buff isn't credited to Ann")
            assert.are.equal(1, friends)
        end)
        it("a player named for one buff can still be named by their receipt for their next", function()
            local used, friends = story({ { "named", "Ann-Vale", "fortitude" }, 0.5,
                { "receipt", "Ann-Vale", "fortitude" }, 3,
                { "unnamed", "fortitude" }, 0.5, { "receipt", "Ann-Vale", "fortitude" } })
            assert.are.equal(1, used)
            assert.are.equal(0, friends)
        end)
        it("someone else's receipt isn't used up by a buff the game named", function()
            local used, friends = story({ { "named", "Ann-Vale", "fortitude" }, 0.5,
                { "unnamed", "fortitude" }, 0.5, { "receipt", "Cid-Rock", "fortitude" } })
            assert.are.equal(1, used, "Cid is named")
            assert.are.equal(0, friends)
        end)
        it("a receipt for another buff isn't used up by a buff the game named", function()
            local used, friends = story({ { "named", "Ann-Vale", "fortitude" }, 0.5,
                { "unnamed", "spirit" }, 0.5, { "receipt", "Ann-Vale", "spirit" } })
            assert.are.equal(1, used, "Ann is named for Divine Spirit")
            assert.are.equal(0, friends)
        end)
        it("a buff the game named long ago uses up no later receipt", function()
            local used, friends = story({ { "named", "Ann-Vale", "fortitude" }, 10,
                { "unnamed", "fortitude" }, 0.5, { "receipt", "Ann-Vale", "fortitude" } })
            assert.are.equal(1, used)
            assert.are.equal(0, friends)
        end)

        it("ignores the receipt: the result is the same as without one", function()
            local with = run(false)
            local without = run(true)
            assert.are.same(without, with)
            assert.are.same({ { target = "Ann-Vale", text = "Thanks Ann: Power Word: Fortitude" } }, with.thanks)
            assert.are.equal("Ann-Vale", with.offer)
        end)
    end)

    describe("more ways the caster can't be read (white)", function()
        local function receiptFor(aura, opts)
            opts = opts or {}
            local ns = wow.boot({ db = { buff = { thankStyle = "whisper", messages = { "Thanks {name}" } },
                buffBack = { enabled = true } } })
            if opts.setup then opts.setup(ns) end
            if opts.before then
                wow.fire("CHAT_MSG_ADDON", "FriendlyFvr", "1;RECEIPT;Ann-Vale;fortitude;?", "WHISPER", "Ann-Vale",
                    "", 0, 0, "", 0)
                wow.advance(opts.before)
            end
            wow.gainBuff(aura or { name = "Power Word: Fortitude", spellId = FORT })
            if opts.after then wow.advance(opts.after) end
            if not opts.before then
                wow.fire("CHAT_MSG_ADDON", "FriendlyFvr", "1;RECEIPT;Ann-Vale;fortitude;?", "WHISPER", "Ann-Vale",
                    "", 0, 0, "", 0)
            end
            if opts.during then opts.during(ns) end
            wow.advance(ns.Receipts.WAIT + ns.db.buff.delay + 0.5)
            wow.keyDown()
            assert.are.same({}, wow.errors)
            return wow.sentTo("WHISPER"), wow.sentTo("SAY"), ns.Offers.Count()
        end

        it("a secret caster unit: named by the receipt", function()
            local whispered = receiptFor({ name = "Power Word: Fortitude", spellId = FORT,
                sourceUnit = wow.secret("nameplate3") })
            assert.are.same({ "Thanks Ann" }, whispered)
        end)
        it("no caster unit, and the game won't say if it's from a player: named by the receipt", function()
            local whispered = receiptFor({ name = "Power Word: Fortitude", spellId = FORT,
                isFromPlayerOrPlayerPet = wow.secret(true) })
            assert.are.same({ "Thanks Ann" }, whispered)
        end)
        it("no caster unit while you're in a group: named by the receipt", function()
            local whispered = receiptFor({ name = "Power Word: Fortitude", spellId = FORT },
                { setup = function() wow.setGroup("party", { "Cid-Rock" }) end })
            assert.are.same({ "Thanks Ann" }, whispered)
        end)
        it("a caster unit whose name is secret: named by the receipt", function()
            local whispered = receiptFor({ name = "Power Word: Fortitude", spellId = FORT, sourceUnit = "nameplate3" },
                { setup = function()
                    wow.addUnit("nameplate3", { name = "Ann", surname = "Vale", id = "Ann-Vale" })
                    wow.state.units.nameplate3.secrets = { name = true }
                end })
            assert.are.same({ "Thanks Ann" }, whispered)
        end)
        it("a receipt that comes 1.9 s after its buff, late in the wait: named", function()
            local whispered = receiptFor(nil, { after = 1.9 })
            assert.are.same({ "Thanks Ann" }, whispered)
        end)
        it("a receipt that came 4.5 s before its buff: named", function()
            local whispered = receiptFor(nil, { before = 4.5 })
            assert.are.same({ "Thanks Ann" }, whispered)
        end)
        it("a buff that isn't one of ours waits for no receipt, and isn't named by one", function()
            local whispered, said = receiptFor({ name = "Blessing of Kings", spellId = 99999 })
            assert.are.same({}, whispered)
            assert.are.equal(1, #said, "the 'friend' thank-you")
        end)
        it("nothing happens if the addon is switched off while the buff waits", function()
            local whispered, said, owed = receiptFor({ name = "Power Word: Fortitude", spellId = FORT },
                { during = function(ns) ns.db.enabled = false end })
            assert.are.same({}, whispered)
            assert.are.same({}, said)
            assert.are.equal(0, owed, "no favour either")
        end)
    end)

    describe("limits (black)", function()
        local function hear(text, sender)
            wow.fire("CHAT_MSG_ADDON", "FriendlyFvr", text, "WHISPER", sender, "", 0, 0, "", 0)
        end

        it("keeps no receipt for an unknown buff, an ignored sender or a group member", function()
            local ns = wow.boot()
            ns.Ignore.Add("Ann-Vale")
            wow.setGroup("party", { "Cid-Rock" })
            hear("1;RECEIPT;Bo-Lake;fireball;?", "Bo-Lake")
            hear("1;RECEIPT;Ann-Vale;fortitude;?", "Ann-Vale")
            hear("1;RECEIPT;Cid-Rock;fortitude;?", "Cid-Rock")
            assert.are.equal(0, ns.Receipts.Count())
            hear("1;RECEIPT;Bo-Lake;fortitude;?", "Bo-Lake")
            assert.are.equal(1, ns.Receipts.Count())
        end)

        it("keeps at most MAX_RECEIPTS, and forgets old ones", function()
            local ns = wow.boot()
            for i = 1, ns.Receipts.MAX_RECEIPTS + 5 do
                local who = "P" .. string.char(96 + i) .. "-Stone"
                hear("1;RECEIPT;" .. who .. ";fortitude;?", who)
            end
            assert.are.equal(ns.Receipts.MAX_RECEIPTS, ns.Receipts.Count())
            wow.advance(ns.Receipts.WINDOW + ns.Receipts.WAIT + 1)
            hear("1;RECEIPT;Bo-Lake;fortitude;?", "Bo-Lake")
            assert.are.equal(1, ns.Receipts.Count())
        end)

        it("lets at most MAX_WAITING buffs wait; past that, a buff doesn't wait", function()
            local ns = wow.boot()
            local answered = 0
            for _ = 1, ns.Receipts.MAX_WAITING do
                ns.Receipts.Await("fortitude", function() answered = answered + 1 end)
            end
            assert.is_true(ns.Receipts.Waiting())
            assert.are.equal(0, answered)
            ns.Receipts.Await("fortitude", function(name)
                assert.is_nil(name)
                answered = answered + 1
            end)
            assert.are.equal(1, answered, "answered at once")
            wow.advance(ns.Receipts.WAIT + 0.1)
            assert.are.equal(ns.Receipts.MAX_WAITING + 1, answered)
            assert.is_false(ns.Receipts.Waiting())
        end)
    end)

    describe("the setting (white)", function()
        it("shows unticked when it was saved off", function()
            local ns = wow.boot({ db = { buff = { receipts = false } } })
            wow.run(ns.Options.widgets.tabs.buff, "OnClick")
            assert.is_false(ns.Options.widgets.receipts:GetChecked())
        end)
        it("without the hidden channel, a buff waits for no receipt", function()
            local ns = wow.boot({ before = function(state) state.noAddonMessages = true end })
            wow.gainBuff({ name = "Power Word: Fortitude", spellId = FORT })
            assert.is_false(ns.Receipts.Waiting())
        end)
        it("shows on the Buff Thanks tab only, and switches receipts off and on", function()
            local ns = wow.boot()
            local w = ns.Options.widgets
            assert.is_true(ns.db.buff.receipts, "on by default")
            wow.run(w.tabs.guildLogin, "OnClick")
            assert.is_false(w.receipts:IsShown())
            wow.run(w.tabs.buff, "OnClick")
            assert.is_true(w.receipts:IsShown())
            assert.is_true(w.receipts:GetChecked())
            w.receipts:SetChecked(false)
            wow.run(w.receipts, "OnClick")
            assert.is_false(ns.db.buff.receipts)
            w.receipts:SetChecked(true)
            wow.run(w.receipts, "OnClick")
            assert.is_true(ns.db.buff.receipts)
        end)
    end)

    describe("a receipt that must change nothing (black)", function()
        -- Bo alone, out of a group, gets a Fortitude whose caster can't be
        -- read, and the receipt `text` from `sender`. The result must be
        -- the same as with no receipt: a "friend" thank-you in /say.
        local function receipt(text, sender, opts)
            opts = opts or {}
            local ns = wow.boot({ db = { buff = { thankStyle = "whisper", messages = { "Thanks {name}: {buff}" } },
                buffBack = { enabled = true } } })
            if opts.setup then opts.setup(ns) end
            if not opts.before and not opts.noBuff then wow.gainBuff({ name = "Power Word: Fortitude", spellId = FORT }) end
            if opts.wait then wow.advance(opts.wait) end
            if type(text) == "table" then
                for _, t in ipairs(text) do
                    wow.fire("CHAT_MSG_ADDON", "FriendlyFvr", t, "WHISPER", sender or "Ann-Vale", "", 0, 0, "", 0)
                end
            elseif text then
                wow.fire("CHAT_MSG_ADDON", "FriendlyFvr", text, "WHISPER", sender or "Ann-Vale", "", 0, 0, "", 0)
            end
            if opts.before then
                wow.advance(opts.before)
                wow.gainBuff({ name = "Power Word: Fortitude", spellId = FORT })
            end
            wow.advance(ns.Receipts.WAIT + ns.db.buff.delay + 0.5)
            wow.keyDown()
            local out = { whispers = {}, say = wow.sentTo("SAY"), owed = ns.Offers.Count() }
            for _, m in ipairs(wow.sent) do
                if m.channel == "WHISPER" then out.whispers[#out.whispers + 1] = m.target end
            end
            assert.are.same({}, wow.errors)
            assert.are.equal(0, count(ns, "luaErrors"))
            return out
        end

        local unchanged
        before_each(function() unchanged = receipt(nil) end)

        local function same(result)
            assert.are.same({}, result.whispers)
            assert.are.equal(0, result.owed)
            assert.are.same(unchanged, result)
            assert.are.equal(1, #unchanged.say, "the 'friend' thank-you, as without a receipt")
        end

        it("with no matching unnamed buff (none arrived)", function()
            local ns = wow.boot({ db = { buff = { thankStyle = "whisper" }, buffBack = { enabled = true } } })
            wow.fire("CHAT_MSG_ADDON", "FriendlyFvr", "1;RECEIPT;Ann-Vale;fortitude;?", "WHISPER", "Ann-Vale",
                "", 0, 0, "", 0)
            wow.advance(30)
            wow.keyDown()
            assert.are.same({}, wow.sent)
            assert.are.equal(0, ns.Offers.Count())
            assert.are.same({}, wow.errors)
        end)

        it("with a key mismatch", function() same(receipt("1;RECEIPT;Ann-Vale;motw;?")) end)
        it("with a key no buff has", function() same(receipt("1;RECEIPT;Ann-Vale;fireball;?")) end)
        it("from a sender on your ignore list", function()
            same(receipt("1;RECEIPT;Ann-Vale;fortitude;?", nil,
                { setup = function(ns) ns.Ignore.Add("Ann-Vale") end }))
        end)
        it("from a sender ignored while the buff waited", function()
            same(receipt("1;RECEIPT;Ann-Vale;fortitude;?", nil, { wait = 0.5,
                setup = function(ns)
                    C_Timer.After(1, function() ns.Ignore.Add("Ann-Vale") end)
                end }))
        end)
        it("for a buff the game names as a groupmate's", function()
            local result = receipt("1;RECEIPT;Ann-Vale;fortitude;?", nil, { noBuff = true, setup = function()
                wow.setGroup("party", { "Cid-Rock" })
                wow.gainBuff({ sourceUnit = "party1", name = "Power Word: Fortitude", spellId = FORT })
            end })
            assert.are.same({}, result.whispers)
            assert.are.same({}, result.say)
            assert.are.equal(0, result.owed)
        end)
        it("from someone the game won't say isn't in your group", function()
            local result = receipt("1;RECEIPT;Ann-Vale;fortitude;?", nil, { setup = function()
                wow.setGroup("party", { "Cid-Rock" })
                wow.state.units.party1.secrets = { name = true }
            end })
            assert.are.same({}, result.whispers)
            assert.are.equal(0, result.owed)
        end)
        it("from a member of your group", function()
            local result = receipt("1;RECEIPT;Ann-Vale;fortitude;?", nil, {
                setup = function() wow.setGroup("party", { "Ann-Vale" }) end })
            assert.are.same({}, result.whispers)
            assert.are.equal(0, result.owed)
        end)
        it("in a flood", function()
            local flood = {}
            for i = 1, 20 do flood[i] = "1;HELLO;Ann-Vale;0.8.0;0" end
            flood[#flood + 1] = "1;RECEIPT;Ann-Vale;fortitude;?"
            same(receipt(flood))
        end)
        it("malformed: a missing field", function() same(receipt("1;RECEIPT;Ann-Vale;fortitude")) end)
        it("malformed: an extra field", function() same(receipt("1;RECEIPT;Ann-Vale;fortitude;?;x")) end)
        it("malformed: a bad key", function() same(receipt("1;RECEIPT;Ann-Vale;fort itude!;?")) end)
        it("malformed: a bad version", function() same(receipt("1;RECEIPT;Ann-Vale;fortitude;|cff")) end)
        it("oversized", function() same(receipt("1;RECEIPT;Ann-Vale;fortitude;?" .. string.rep("x", 300))) end)
        it("with the wrong protocol version", function() same(receipt("2;RECEIPT;Ann-Vale;fortitude;?")) end)
        it("with a spoofed sender", function()
            same(receipt("1;RECEIPT;Ann-Vale;fortitude;?", "Cid-Rock"))
        end)
        it("with an unreadable sender", function()
            same(receipt("1;RECEIPT;Ann-Vale;fortitude;?", wow.secret("Ann-Vale")))
        end)
        it("on a group route", function()
            local ns = wow.boot({ db = { buff = { thankStyle = "whisper" } } })
            wow.setGroup("party", { "Cid-Rock" })
            wow.gainBuff({ name = "Power Word: Fortitude", spellId = FORT })
            wow.fire("CHAT_MSG_ADDON", "FriendlyFvr", "1;RECEIPT;Ann-Vale;fortitude;?", "PARTY", "Ann-Vale",
                "", 0, 0, "", 0)
            wow.advance(10)
            assert.are.same({}, wow.sentTo("WHISPER"))
            assert.are.equal(1, count(ns, "commWrongRoute"))
        end)
        it("that came too long before the buff", function()
            same(receipt("1;RECEIPT;Ann-Vale;fortitude;?", nil, { before = 6 }))
        end)
        it("that came too long after the buff", function()
            same(receipt("1;RECEIPT;Ann-Vale;fortitude;?", nil, { wait = 3 }))
        end)
        it("from two players for one buff: nobody is named", function()
            local result = receipt(nil, nil, { setup = function()
                C_Timer.After(0.5, function()
                    wow.fire("CHAT_MSG_ADDON", "FriendlyFvr", "1;RECEIPT;Ann-Vale;fortitude;?", "WHISPER", "Ann-Vale",
                        "", 0, 0, "", 0)
                    wow.fire("CHAT_MSG_ADDON", "FriendlyFvr", "1;RECEIPT;Cid-Rock;fortitude;?", "WHISPER", "Cid-Rock",
                        "", 0, 0, "", 0)
                end)
            end })
            same(result)
        end)
        it("a used receipt names no second buff", function()
            local ns = wow.boot({ db = { buff = { thankStyle = "whisper", repeatCooldown = 0 } } })
            wow.gainBuff({ name = "Power Word: Fortitude", spellId = FORT })
            wow.fire("CHAT_MSG_ADDON", "FriendlyFvr", "1;RECEIPT;Ann-Vale;fortitude;?", "WHISPER", "Ann-Vale",
                "", 0, 0, "", 0)
            wow.advance(ns.Receipts.WAIT + 0.1)
            wow.loseBuff(FORT)
            wow.gainBuff({ name = "Power Word: Fortitude", spellId = FORT })
            wow.advance(30)
            wow.keyDown()
            assert.are.equal(1, #wow.sentTo("WHISPER"), "the first buff is Ann's")
            assert.are.equal(1, #wow.sentTo("SAY"), "the second is 'friend''s")
        end)
    end)

    describe("no receipt is sent (black)", function()
        -- Ann alone casts Fortitude on Bo by hand; the receipts her game accepted.
        local function cast(opts)
            opts = opts or {}
            local ns = wow.boot({ db = opts.db, before = function(state)
                state.class, state.knownSpells = "PRIEST", { [FORT] = true }
                if opts.before then opts.before(state) end
            end })
            if opts.setup then opts.setup(ns) end
            wow.addUnit("target", BO)
            wow.runMacro("/cast Power Word: Fortitude")
            wow.advance(15)
            assert.are.same({}, wow.errors)
            return #receiptsIn(wow.addonSent), #wow.landed
        end

        it("but one is, to a stranger, for a cast that landed", function()
            local sent, landed = cast()
            assert.are.equal(1, landed)
            assert.are.equal(1, sent)
        end)
        it("to a group member", function()
            local sent, landed = cast({ setup = function() wow.setGroup("party", { "Bo-Lake" }) end })
            assert.are.equal(1, landed)
            assert.are.equal(0, sent)
        end)
        it("to someone the game won't say isn't in your group", function()
            local sent = cast({ setup = function()
                wow.setGroup("party", { "Cid-Rock" })
                wow.state.units.party1.secrets = { name = true }
            end })
            assert.are.equal(0, sent)
        end)
        it("to someone on your ignore list", function()
            assert.are.equal(0, (cast({ setup = function(ns) ns.Ignore.Add("Bo-Lake") end })))
        end)
        it("to yourself", function()
            wow.boot({ before = function(state) state.class, state.knownSpells = "PRIEST", { [FORT] = true } end })
            wow.runMacro("/cast Power Word: Fortitude")
            assert.are.equal(1, #wow.landed)
            assert.are.equal(0, #receiptsIn(wow.addonSent))
        end)
        it("inside an instance", function()
            local sent, landed = cast({ before = function(state) state.inInstance = true end })
            assert.are.equal(1, landed)
            assert.are.equal(0, sent)
        end)
        it("when the game won't say whether you're in an instance", function()
            local sent = cast({ setup = function()
                _G.IsInInstance = function() return wow.secret(false), "none" end
            end })
            assert.are.equal(0, sent)
        end)
        it("during chat lockdown", function()
            local sent, landed = cast({ setup = function() wow.state.lockdown = true end })
            assert.are.equal(1, landed)
            assert.are.equal(0, sent)
        end)
        it("with the setting off", function()
            local sent, landed = cast({ db = { buff = { receipts = false } } })
            assert.are.equal(1, landed)
            assert.are.equal(0, sent)
        end)
        it("with buff thanks off", function()
            local sent, landed = cast({ db = { buff = { enabled = false } } })
            assert.are.equal(1, landed)
            assert.are.equal(0, sent)
        end)
        it("with the addon off", function()
            assert.are.equal(0, (cast({ db = { enabled = false } })))
        end)
        it("for a cast that failed", function()
            local sent, landed = cast({ before = function(state) state.castFailures["Bo-Lake"] = "Out of range" end })
            assert.are.equal(0, landed)
            assert.are.equal(0, sent)
        end)
        it("twice, when the game repeats a cast's success", function()
            -- The cast's GUID, as the game gave it.
            local fire, guid = wow.fire, nil
            wow.fire = function(event, ...)
                if event == "UNIT_SPELLCAST_SUCCEEDED" then guid = select(2, ...) end
                return fire(event, ...)
            end
            local ok, err = pcall(cast)
            wow.fire = fire
            assert(ok, err)
            assert.is_not_nil(guid)
            wow.fire("UNIT_SPELLCAST_SUCCEEDED", "player", guid, FORT)
            assert.are.equal(1, #receiptsIn(wow.addonSent))
        end)
        it("for a cast the game can't say went to a player", function()
            local sent = cast({ before = function(state) state.sentTargetForm = "none" end })
            assert.are.equal(0, sent)
        end)
        it("for a cast by hand with buff back off: still sent, as it's for thanks", function()
            assert.are.equal(1, (cast({ db = { buffBack = { enabled = false } } })))
            -- Buff back off still remembers nothing of the cast: no exchange, no plan.
            for _, m in ipairs(wow.addonSent) do assert.is_nil(m.text:find(";PLAN;", 1, true)) end
        end)
        it("for no buff, or for yourself, when asked directly", function()
            local ns = wow.boot()
            assert.is_false(ns.Receipts.Send("Bo-Lake", nil))
            assert.is_false(ns.Receipts.Send("Bo-Lake", ns.BuffData.REVOKE))
            assert.is_false(ns.Receipts.Send(wow.state.units.player.id, ns.BuffData.ByKey("fortitude")))
            assert.is_true(ns.Receipts.Send("Bo-Lake", ns.BuffData.ByKey("fortitude")))
            assert.are.equal(1, #receiptsIn(wow.addonSent))
        end)
    end)

    -- Ann, Bo and Dee buff each other at random. Each walks in and out of
    -- the others' view, messages are lost or arrive late, and Cid, who never
    -- casts, sends false receipts. Per event, from the simulated clients
    -- alone (wow.landed, wow.addonSent, wow.sent):
    --   * no client sends a player more receipts than its casts that landed
    --     on them;
    --   * every buff a thank-you lists landed on the thanker, with that
    --     spell, a bounded time before it; and, unless it names Cid, from the
    --     player it names. Cid can be named only when a real caster's receipt
    --     was lost and nobody else's clashed with his: the receipt is a hint;
    --   * nothing errors.
    describe("a chaos storm of buffs (red)", function()
        local PRIEST = { [FORT] = true, [SPIRIT] = true }
        local CASTERS = {
            { name = "Ann", surname = "Vale", class = "PRIEST", id = "Ann-Vale", spells = PRIEST,
                cast = { "Power Word: Fortitude", "Divine Spirit" } },
            { name = "Bo", surname = "Lake", class = "DRUID", id = "Bo-Lake", spells = { [MOTW] = true, [THORNS] = true },
                cast = { "Mark of the Wild", "Thorns" } },
            { name = "Dee", surname = "Moss", class = "MAGE", id = "Dee-Moss", spells = { [10157] = true },
                cast = { "Arcane Intellect" } },
        }
        local LIAR = "Cid-Rock"
        local KEY_OF = { ["Power Word: Fortitude"] = "fortitude", ["Divine Spirit"] = "spirit",
            ["Mark of the Wild"] = "motw", ["Thorns"] = "thorns", ["Arcane Intellect"] = "intellect" }
        local KEYS = { "fortitude", "spirit", "motw", "thorns", "intellect" }

        -- The buffs a thank-you lists: "Thanks Ann: A, B and C".
        local function listed(text)
            local list = text:match("^Thanks %a+: (.*)$")
            local out = {}
            if not list then return out end
            list = list:gsub(" and ", ", ")
            for name in (list .. ", "):gmatch("(.-), ") do out[#out + 1] = name end
            return out
        end

        local function storm(seed)
            random.seed(seed)
            local clients = {}
            for i, p in ipairs(CASTERS) do
                clients[i] = wow.newClient({ name = p.name, surname = p.surname,
                    db = { buff = { thankStyle = "whisper", repeatCooldown = 0, listBuffNames = true,
                        messages = { "Thanks {name}: {buff}" } }, buffBack = { enabled = true } },
                    before = function(state) state.class, state.knownSpells = p.class, p.spells end })
                -- Loading fills a short list from the shipped lines: one line only.
                clients[i].ns.db.buff.messages = { "Thanks {name}: {buff}" }
            end
            net = wow.network(clients)
            local reach = { receipts = 0, named = 0, used = 0, liar = 0, clashes = 0, lost = 0, late = 0 }
            net.lose = function()
                local lost = random.random() < 0.2
                if lost then reach.lost = reach.lost + 1 end
                return lost
            end
            wow.use(clients[1])
            local R = clients[1].ns.Receipts
            local bound = R.WAIT + clients[1].ns.Exchange.MAX_DELAY + 1
            -- Cid's false receipts to each client: { key, at, used }.
            local lies = {}

            -- Every buff landed on this client: { from, spell, at }.
            local function landedOn(c)
                local out = {}
                for _, other in ipairs(clients) do
                    wow.use(other)
                    for _, l in ipairs(wow.landed) do
                        if l.target == c.full then out[#out + 1] = { from = other.full, spell = l.spell, at = l.at } end
                    end
                end
                return out
            end

            local seen = {}
            local function check(where)
                for _, c in ipairs(clients) do
                    wow.use(c)
                    local landed, receiptsTo = {}, {}
                    for _, l in ipairs(wow.landed) do landed[l.target] = (landed[l.target] or 0) + 1 end
                    for _, m in ipairs(receiptsIn(wow.addonSent)) do
                        receiptsTo[m.target] = (receiptsTo[m.target] or 0) + 1
                    end
                    for target, n in pairs(receiptsTo) do
                        assert.is_true(n <= (landed[target] or 0), where .. ": more receipts than casts to " .. target)
                    end
                    assert.are.same({}, wow.errors, where)
                    assert.are.equal(0, count(c.ns, "luaErrors"), where)
                end
                for _, c in ipairs(clients) do
                    wow.use(c)
                    local sent = {}
                    for _, m in ipairs(wow.sent) do sent[#sent + 1] = m end
                    local arrived = landedOn(c)
                    for i = (seen[c] or 0) + 1, #sent do
                        local m = sent[i]
                        assert.are.equal("WHISPER", m.channel, where .. ": only whispered thank-yous")
                        local buffs = listed(m.text)
                        assert.is_true(#buffs > 0, where .. ": a thank-you listing its buffs: " .. m.text)
                        for _, spell in ipairs(buffs) do
                            local ok = false
                            for _, l in ipairs(arrived) do
                                if not ok and l.spell == spell and l.at <= m.time and m.time - l.at <= bound then
                                    if m.target ~= LIAR then
                                        ok = l.from == m.target
                                    else
                                        -- One of Cid's receipts, of this buff's key, from up to
                                        -- WINDOW before it to WAIT after, used once.
                                        for _, lie in ipairs(lies[c] or {}) do
                                            if not ok and not lie.used and lie.key == KEY_OF[spell]
                                                and lie.at >= l.at - R.WINDOW - 1e-6 and lie.at <= l.at + R.WAIT + 1e-6 then
                                                lie.used, ok = true, true
                                            end
                                        end
                                    end
                                end
                            end
                            assert.is_true(ok, where .. ": " .. c.full .. " thanked " .. tostring(m.target)
                                .. " for " .. spell .. ", which they didn't give")
                        end
                        if m.target == LIAR then reach.liar = reach.liar + 1 end
                    end
                    seen[c] = #sent
                end
            end

            for step = 1, 90 do
                local i = random.random(#clients)
                local x = clients[i]
                local roll = random.random()
                local where = string.format("seed %d step %d", seed, step)
                if roll < 0.45 then
                    local j = random.random(#clients - 1)
                    if j >= i then j = j + 1 end
                    local spells = CASTERS[i].cast
                    wow.use(x)
                    wow.addUnit("target", CASTERS[j])
                    wow.runMacro("/cast " .. spells[random.random(#spells)])
                    wow.state.units.target = nil
                    wow.deliverBuffs(net)
                    -- Messages arrive now, or late: within the wait, or past it.
                    local lag = ({ 0, 0, 0.5, 1.25, 1.75, 3 })[random.random(6)]
                    if lag > 0 then wow.advanceAll(net, lag, lag) end
                    wow.deliver(net)
                    -- Late in the wait: did that receipt name the caster?
                    if lag > 1 and lag < x.ns.Receipts.WAIT then
                        local target = clients[j]
                        wow.use(target)
                        local before = count(target.ns, "receiptsUsed")
                        wow.advanceAll(net, x.ns.Receipts.WAIT - lag + 0.25, 0.25)
                        wow.use(target)
                        if count(target.ns, "receiptsUsed") > before then reach.late = reach.late + 1 end
                    end
                elseif roll < 0.55 then
                    wow.use(x)
                    if wow.state.units.nameplate1 then
                        wow.state.units.nameplate1 = nil
                    else
                        local j = random.random(#CASTERS)
                        if j ~= i then wow.addUnit("nameplate1", CASTERS[j]) end
                    end
                elseif roll < 0.75 then
                    -- Cid's false receipt: his buff never came.
                    wow.use(x)
                    local key = KEYS[random.random(#KEYS)]
                    lies[x] = lies[x] or {}
                    table.insert(lies[x], { key = key, at = wow.now })
                    wow.fire("CHAT_MSG_ADDON", "FriendlyFvr", "1;RECEIPT;" .. LIAR .. ";" .. key
                        .. ";?", "WHISPER", LIAR, "", 0, 0, "", 0)
                elseif roll < 0.8 then
                    wow.use(x)
                    x.ns.BuffButton.Refresh()
                    wow.press(x.ns.BuffButton.Frame())
                    settle()
                else
                    wow.advanceAll(net, ({ 0.5, 1, 2, 3, 6 })[random.random(5)], 0.25)
                end
                check(where)
            end
            wow.advanceAll(net, 40, 0.5)
            check(string.format("seed %d end", seed))
            for _, c in ipairs(clients) do
                wow.use(c)
                reach.receipts = reach.receipts + #receiptsIn(wow.addonSent)
                reach.named = reach.named + #wow.sent
                reach.used = reach.used + count(c.ns, "receiptsUsed")
                reach.clashes = reach.clashes + count(c.ns, "receiptsClashed")
            end
            return reach
        end

        it("never sends more than one receipt per successful cast, never names a non-caster, never errors", function()
            local total = { receipts = 0, named = 0, used = 0, liar = 0, clashes = 0, lost = 0, late = 0 }
            for seed = 1, 16 do
                local reach = storm(seed)
                assert.is_true(reach.used > 0, "seed " .. seed .. ": receipts named casters")
                for k, v in pairs(reach) do total[k] = total[k] + v end
            end
            -- The storm reached what it tests.
            assert.is_true(total.receipts > 30, "receipts were sent: " .. total.receipts)
            assert.is_true(total.named > 15, "casters were thanked: " .. total.named)
            assert.is_true(total.used > 10, "receipts named casters: " .. total.used)
            assert.is_true(total.late > 5, "receipts late in the wait named their casters: " .. total.late)
            assert.is_true(total.lost > 10, "messages were lost: " .. total.lost)
            assert.is_true(total.clashes > 0, "receipts from two players for one buff: " .. total.clashes)
            assert.is_true(total.liar > 0, "Cid named for a buff whose receipt was lost: " .. total.liar)
        end)
    end)
end)

describe("After an update that adds Receipts.lua and a /reload (no restart) (black)", function()
    it("asks for a restart instead of erroring, and thanks nobody", function()
        wow.reset()
        local loaded = {}
        local _, files = wow.parseToc()
        for _, file in ipairs(files) do
            if file ~= "Receipts.lua" then assert(loadfile(wow.ROOT .. file))(wow.ADDON_NAME, loaded) end
        end
        wow.fire("ADDON_LOADED", wow.ADDON_NAME)
        wow.fire("PLAYER_ENTERING_WORLD", true, false)
        wow.advance(60)
        wow.gainBuff({ name = "Power Word: Fortitude", spellId = FORT })
        wow.advance(60)
        wow.keyDown()
        assert.are.same({}, wow.errors)
        assert.are.same({}, wow.sent)
        assert.is_truthy(table.concat(wow.printed, "\n"):find("Restart the game", 1, true))
    end)
end)
