-- Spec: #36
-- Buff exchanges: one thank-you each way, sent after the last buff. Each
-- side's thank-you is held while the exchange goes on, lists every buff it
-- got, and always goes out within Exchange.MAX_DELAY.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local FORT, SPIRIT, SHADOW = 10938, 27841, 10958
local MOTW, THORNS = 9885, 9910

local function count(ns, key)
    return ns.Diag.Counters()[key] or 0
end

describe("Buff exchanges between two copies of the addon (#36)", function()
    local a, b, net, E

    -- Ann Vale, a priest with three buffs, and Bo Lake, a druid with two,
    -- out in the world; each sees the other on a nameplate. Thank-yous are
    -- whispered, so no key press is needed. opts.noComm: neither has addon
    -- messages; opts.db: extra buff settings for both.
    local function pair(opts)
        opts = opts or {}
        local function setup(class, known, other)
            return function(state)
                state.class, state.knownSpells = class, known
                state.noAddonMessages = opts.noComm or nil
                wow.addUnit("nameplate1", other)
            end
        end
        local function db()
            local buff = { thankStyle = "whisper", messages = { "Thanks {name}: {buff}" } }
            for k, v in pairs(opts.db or {}) do buff[k] = v end
            return { buff = buff }
        end
        a = wow.newClient({ name = "Ann", surname = "Vale", db = db(),
            before = setup("PRIEST", { [FORT] = true, [SPIRIT] = true, [SHADOW] = true },
                { name = "Bo", surname = "Lake", class = "DRUID", id = "Bo-Lake" }) })
        b = wow.newClient({ name = "Bo", surname = "Lake", db = db(),
            before = setup("DRUID", { [MOTW] = true, [THORNS] = true },
                { name = "Ann", surname = "Vale", class = "PRIEST", id = "Ann-Vale" }) })
        net = wow.network({ a, b })
        E = a.ns.Exchange
    end

    -- Buffs that landed reach the other side, then addon messages, after
    -- lag() seconds (a storm sets it; none otherwise).
    local lag
    before_each(function() lag = nil end)

    local function settle()
        wow.deliverBuffs(net)
        local seconds = lag and lag() or 0
        if seconds > 0 then wow.advanceAll(net, seconds, seconds) end
        wow.deliver(net)
    end

    local function advance(seconds)
        wow.advanceAll(net, seconds, 0.25)
    end

    -- The client targets the other and casts this buff by hand.
    local function handCast(client, spell)
        wow.use(client)
        wow.addUnit("target", wow.state.units.nameplate1)
        wow.runMacro("/cast " .. spell)
        settle()
    end

    local function press(client, mouseButton)
        wow.use(client)
        wow.press(client.ns.BuffButton.Frame(), mouseButton)
        settle()
    end

    -- The thank-yous this client's game sent: { text, target, time }.
    local function thanks(client)
        wow.use(client)
        local out = {}
        for _, m in ipairs(wow.sent) do
            if m.channel == "WHISPER" then out[#out + 1] = m end
        end
        return out
    end

    -- When this client's last buff landed.
    local function lastLanded(client)
        wow.use(client)
        return wow.landed[#wow.landed].at
    end

    -- The PLAN messages this client's game accepted, as their field.
    local function plansSent(client)
        wow.use(client)
        local out = {}
        for _, m in ipairs(wow.addonSent) do
            local plan = m.text:match(";PLAN;[^;]*;(.*)$")
            if plan then out[#out + 1] = plan end
        end
        return out
    end

    -- The issue's story: Ann buffs Bo three times by hand; Bo returns one
    -- with the button and one by hand.
    local function threeInTwoBack()
        handCast(a, "Power Word: Fortitude")
        advance(1.5)
        handCast(a, "Divine Spirit")
        advance(1.5)
        handCast(a, "Shadow Protection")
        advance(1)
        press(b)
        advance(1.5)
        handCast(b, "Thorns")
    end

    it("waits as the owner decided: 2 s settle, a 5 s cap, 30 s at most, exchanges end after 10 s", function()
        pair()
        assert.are.same({ 2, 5, 30, 10 }, { E.SETTLE, E.HOLD_CAP, E.MAX_DELAY, E.GAP })
    end)

    describe("with the hidden channel (white)", function()
        it("3 buffs in and 2 back: one thank-you each, each after the last buff, each listing all its buffs", function()
            pair()
            threeInTwoBack()
            assert.are.same({}, thanks(a), "Ann waits for Bo's last buff")
            assert.are.same({}, thanks(b), "Bo waits until he's done buffing back")
            advance(E.MAX_DELAY)
            local fromA, fromB = thanks(a), thanks(b)
            assert.are.equal(1, #fromA)
            assert.are.equal(1, #fromB)
            assert.are.equal("Bo-Lake", fromA[1].target)
            assert.are.equal("Thanks Bo: Mark of the Wild and Thorns", fromA[1].text)
            assert.are.equal("Ann-Vale", fromB[1].target)
            assert.are.equal("Thanks Ann: Power Word: Fortitude, Divine Spirit and Shadow Protection", fromB[1].text)
            local last = math.max(lastLanded(a), lastLanded(b))
            assert.is_true(fromA[1].time > last and fromB[1].time > last, "both after the last buff either way")
            assert.is_true(fromA[1].time <= last + E.SETTLE + E.TICK, "and soon after it")
            assert.is_true(fromB[1].time <= last + E.SETTLE + E.TICK, "and soon after it")
        end)

        it("each copy announces what its button holds for the other, and when that's done", function()
            pair()
            threeInTwoBack()
            advance(E.MAX_DELAY)
            assert.are.same({ "motw", "-" }, plansSent(b))
            assert.are.same({ "-" }, plansSent(a), "Ann's button never held Bo: her buffs opened")
        end)

        it("a slow press past the planless cap: Bo's thank-you still waits for his buff back", function()
            pair()
            handCast(a, "Power Word: Fortitude")
            advance(E.HOLD_CAP + 5)
            assert.are.same({}, thanks(b), "his button is armed for her, and her copy is there")
            press(b)
            advance(E.SETTLE + E.TICK)
            assert.are.equal(1, #thanks(b))
            assert.is_true(thanks(b)[1].time > lastLanded(b))
            advance(E.MAX_DELAY)
            assert.are.equal(1, #thanks(a))
        end)

        it("an armed button nobody presses holds the thank-you up to the longest wait, no longer", function()
            pair()
            handCast(a, "Power Word: Fortitude")
            local firstAt = wow.now
            advance(E.MAX_DELAY - 2)
            assert.are.same({}, thanks(b))
            advance(4)
            assert.are.equal(1, #thanks(b))
            assert.is_true(thanks(b)[1].time >= firstAt + E.MAX_DELAY)
            assert.is_true(thanks(b)[1].time <= firstAt + E.MAX_DELAY + E.TICK)
        end)

        it("letting the favour go ends the hold", function()
            pair()
            handCast(a, "Power Word: Fortitude")
            advance(8)
            press(b, "RightButton")
            assert.are.equal(0, b.ns.Offers.Count(), "let go")
            advance(E.TICK + 0.5)
            assert.are.equal(1, #thanks(b))
        end)

        it("a buff from them after the thank-you, in the same exchange, isn't thanked again", function()
            pair({ db = { repeatCooldown = 0 } })
            threeInTwoBack()
            advance(E.SETTLE + E.TICK + 1)
            assert.are.equal(1, #thanks(b))
            handCast(a, "Power Word: Fortitude")
            advance(E.MAX_DELAY)
            assert.are.equal(1, #thanks(b), "one thank-you per exchange, whatever the cooldown")
            wow.use(b)
            local entries = b.ns.db.ledger.entries
            assert.are.equal("thanked them already in this exchange", entries[#entries].note)
        end)

        it("sends at most MAX_PLANS_SENT plans in one exchange, however often the button changes", function()
            pair()
            for _ = 1, 4 do
                handCast(a, "Power Word: Fortitude")
                advance(E.TICK + 0.5)
                press(b, "RightButton")
                advance(E.TICK + 0.5)
            end
            assert.are.same({ "motw", "-", "motw", "-" }, plansSent(b))
            assert.are.equal(E.MAX_PLANS_SENT, #plansSent(b))
        end)

        it("a line in /say and a /thank: both held, and each goes once", function()
            pair({ db = { thankStyle = "both" } })
            handCast(a, "Power Word: Fortitude")
            for _ = 1, 8 do
                advance(1)
                wow.use(b)
                wow.keyDown()
            end
            wow.use(b)
            assert.are.same({}, wow.emotes, "the /thank waits for his buff back too")
            assert.are.same({}, wow.sentTo("SAY"))
            press(b)
            for _ = 1, 4 do
                advance(1)
                wow.use(b)
                wow.keyDown()
            end
            advance(E.MAX_DELAY)
            wow.use(b)
            assert.are.equal(1, #wow.emotes)
            local lines = {}
            for _, m in ipairs(wow.sent) do if m.channel == "SAY" then lines[#lines + 1] = m end end
            assert.are.equal(1, #lines)
            assert.is_true(wow.emotes[1].time > lastLanded(b))
            assert.is_true(lines[1].time > lastLanded(b))
        end)

        it("a new exchange after a quiet gap has its own thank-you", function()
            pair({ db = { repeatCooldown = 0 } })
            handCast(a, "Power Word: Fortitude")
            press(b)
            advance(E.MAX_DELAY)
            assert.are.equal(1, #thanks(b))
            advance(E.GAP)
            handCast(a, "Divine Spirit")
            advance(E.MAX_DELAY)
            assert.are.equal(2, #thanks(b))
        end)
    end)

    describe("without the hidden channel (white)", function()
        it("3 buffs in and 2 back: one thank-you each, sent within the cap", function()
            pair({ noComm = true })
            threeInTwoBack()
            assert.are.same({}, thanks(a))
            assert.are.same({}, thanks(b))
            advance(E.MAX_DELAY)
            local fromA, fromB = thanks(a), thanks(b)
            assert.are.equal(1, #fromA)
            assert.are.equal(1, #fromB)
            assert.are.equal("Thanks Bo: Mark of the Wild and Thorns", fromA[1].text)
            assert.are.equal("Thanks Ann: Power Word: Fortitude, Divine Spirit and Shadow Protection", fromB[1].text)
            local last = math.max(lastLanded(a), lastLanded(b))
            for _, t in ipairs({ fromA[1], fromB[1] }) do
                assert.is_true(t.time > last and t.time <= last + E.HOLD_CAP + E.TICK, "within the cap")
            end
        end)

        it("an armed button holds the thank-you only up to the cap after the last buff", function()
            pair({ noComm = true })
            handCast(a, "Power Word: Fortitude")
            local at = wow.now
            advance(E.HOLD_CAP - 1)
            assert.are.same({}, thanks(b), "held while armed")
            advance(2 * E.TICK)
            assert.are.equal(1, #thanks(b))
            assert.is_true(thanks(b)[1].time >= at + E.HOLD_CAP and thanks(b)[1].time <= at + E.HOLD_CAP + E.TICK)
            press(b)
            advance(E.MAX_DELAY)
            assert.are.equal(1, #thanks(b), "his late buff back doesn't make another")
            assert.are.equal(1, #thanks(a), "and Ann thanks him once")
        end)

        it("a delay longer than the exchange: the thank-you goes when the delay ends", function()
            pair({ noComm = true, db = { delay = E.GAP + 5 } })
            handCast(a, "Power Word: Fortitude")
            local at = wow.now
            advance(E.GAP + 5 + E.TICK)
            assert.are.equal(1, #thanks(b))
            assert.are.equal(at + E.GAP + 5, thanks(b)[1].time)
        end)

        it("once every exchange is over, nothing keeps ticking", function()
            pair({ noComm = true })
            wow.use(b)
            b.ns.db.buffBack.enabled = false
            handCast(a, "Power Word: Fortitude")
            advance(E.MAX_DELAY + E.GAP)
            wow.use(b)
            assert.are.equal(1, #thanks(b))
            assert.are.same({}, wow.timers)
        end)

        it("a button armed for someone else holds nobody else's thank-you", function()
            pair({ noComm = true })
            handCast(a, "Power Word: Fortitude")
            local at = wow.now
            advance(1)
            wow.use(b)
            wow.addUnit("nameplate2", { name = "Cid", surname = "Rock", class = "WARRIOR", id = "Cid-Rock" })
            wow.gainBuff({ sourceUnit = "nameplate2", name = "Arcane Intellect", spellId = 10157 })
            assert.are.equal("Cid-Rock", b.ns.BuffButton.ArmedOffer().name, "the newest favour is armed")
            advance(b.ns.db.buff.delay)
            assert.are.equal(1, #thanks(b))
            assert.are.equal("Ann-Vale", thanks(b)[1].target)
            assert.are.equal(at + b.ns.db.buff.delay, thanks(b)[1].time, "no wait for Cid's button")
        end)

        it("an exchange ends GAP seconds after its last buff either way, not before", function()
            pair({ noComm = true, db = { repeatCooldown = 0 } })
            wow.use(b)
            b.ns.db.buffBack.enabled = false
            handCast(a, "Power Word: Fortitude")
            advance(E.GAP - 1)
            assert.are.equal(1, #thanks(b))
            handCast(a, "Divine Spirit")
            advance(E.GAP + E.TICK)
            assert.are.equal(1, #thanks(b), "still the same exchange, its last buff now later")
            handCast(a, "Shadow Protection")
            advance(E.MAX_DELAY)
            assert.are.equal(2, #thanks(b), "a new exchange")
        end)

        it("with nothing to give back, a single buff is thanked after the usual delay", function()
            pair({ noComm = true })
            wow.use(b)
            b.ns.db.buffBack.enabled = false
            -- Another exchange starts the ticks half a second out of step (its
            -- thank-you goes well before Ann's: ChatQueue.MIN_INTERVAL).
            wow.addUnit("nameplate2", { name = "Cid", surname = "Rock", class = "WARRIOR", id = "Cid-Rock" })
            wow.gainBuff({ sourceUnit = "nameplate2", name = "Arcane Intellect", spellId = 10157 })
            advance(2.5)
            handCast(a, "Power Word: Fortitude")
            local at = wow.now
            advance(b.ns.db.buff.delay + E.TICK)
            local toAnn = {}
            for _, t in ipairs(thanks(b)) do if t.target == "Ann-Vale" then toAnn[#toAnn + 1] = t end end
            assert.are.equal(1, #toAnn)
            assert.are.equal(at + b.ns.db.buff.delay, toAnn[1].time, "at once, not at the next tick")
        end)
    end)

    describe("lost, spoofed and abandoned exchanges (black)", function()
        -- Inject an addon message to the live client as if from sender.
        -- A second apart, within the flood limit (Comm.PEER_REFILL).
        local function receive(text, route, sender)
            wow.advance(1)
            wow.fire("CHAT_MSG_ADDON", "FriendlyFvr", text, route or "WHISPER", sender or "Bo-Lake", "", 0, 0, "", 0)
        end

        it("a lost announcement: still one thank-you each, within the longest wait", function()
            pair()
            net.lose = function(msg) return msg.text:find(";PLAN;", 1, true) ~= nil end
            local firstAt = wow.now
            threeInTwoBack()
            advance(E.MAX_DELAY * 2)
            assert.is_true(#plansSent(b) > 0, "plans were sent, and lost")
            assert.are.equal(1, #thanks(a))
            assert.are.equal(1, #thanks(b))
            assert.is_true(thanks(b)[1].time <= firstAt + E.MAX_DELAY)
            assert.is_true(thanks(a)[1].time <= firstAt + E.MAX_DELAY)
        end)

        it("a lost \"done\": the buff that arrives crosses itself off", function()
            pair()
            net.lose = function(msg) return msg.text:find(";PLAN;Bo%-Lake;%-$") ~= nil end
            threeInTwoBack()
            advance(E.SETTLE + 2 * E.TICK)
            assert.are.equal(1, #thanks(a), "not held for Bo's Mark, which came")
        end)

        it("a spoofed plan of buffs that never come holds the thank-you no longer than the longest wait", function()
            pair()
            handCast(b, "Thorns")
            wow.use(a)
            local firstAt = wow.now
            -- Ann lets her favour go, so only the plan could hold her thank-you,
            -- and Bo's real plan ("-") comes first.
            wow.press(a.ns.BuffButton.Frame(), "RightButton")
            advance(E.TICK + 0.5)
            assert.are.same({ "-" }, plansSent(b))
            wow.use(a)
            receive("1;PLAN;Bo-Lake;fortitude,kings,motw")
            advance(E.MAX_DELAY - 5)
            assert.are.same({}, thanks(a), "held for the plan")
            advance(4)
            assert.are.equal(1, #thanks(a))
            assert.is_true(thanks(a)[1].time <= firstAt + E.MAX_DELAY + E.TICK)
            advance(E.MAX_DELAY)
            assert.are.equal(1, #thanks(a), "once")
        end)

        it("a plan about someone else, on a group route, malformed, or with no exchange holds nothing", function()
            pair({ noComm = false })
            handCast(b, "Thorns")
            wow.use(a)
            -- Ann's own button is armed for Bo: let it go, so only plans could hold her.
            wow.press(a.ns.BuffButton.Frame(), "RightButton")
            local before = count(a.ns, "commSpoofed") + count(a.ns, "commMalformed") + count(a.ns, "commWrongRoute")
            receive("1;PLAN;Cid-Rock;motw") -- about someone else
            receive("1;PLAN;Bo-Lake;a,b,c,d,e,f,g,h,i") -- too many keys
            receive("1;PLAN;Bo-Lake;motw,,thorns") -- an empty key
            receive("1;PLAN;Bo-Lake;mo-tw") -- not a key
            receive("1;PLAN;Bo-Lake;") -- no keys at all
            receive("1;PLAN;Bo-Lake;motw;x") -- an extra field
            wow.setGroup("party", { "Bo-Lake" })
            receive("1;PLAN;Bo-Lake;motw", "PARTY") -- a group route
            wow.setGroup(nil)
            local after = count(a.ns, "commSpoofed") + count(a.ns, "commMalformed") + count(a.ns, "commWrongRoute")
            assert.are.equal(before + 7, after, "each one dropped")
            receive("1;PLAN;Cid-Rock;motw", "WHISPER", "Cid-Rock") -- no exchange with Cid
            receive("1;PLAN;Bo-Lake;nothing,known") -- keys of no buff
            advance(a.ns.db.buff.delay + E.TICK)
            assert.are.equal(1, #thanks(a), "nothing held it")
            assert.are.same({}, wow.errors)
        end)

        it("a plan from someone you aren't exchanging with is forgotten, not kept for their buff", function()
            pair()
            wow.use(a)
            a.ns.db.buffBack.enabled = false -- nothing of Ann's own holds her thank-you
            receive("1;PLAN;Cid-Rock;motw", "WHISPER", "Cid-Rock")
            wow.addUnit("nameplate2", { name = "Cid", surname = "Rock", class = "DRUID", id = "Cid-Rock" })
            wow.gainBuff({ sourceUnit = "nameplate2", name = "Thorns", spellId = THORNS })
            local at = wow.now
            advance(a.ns.db.buff.delay + E.TICK)
            assert.are.equal(1, #thanks(a))
            assert.are.equal("Cid-Rock", thanks(a)[1].target)
            assert.is_true(thanks(a)[1].time <= at + a.ns.db.buff.delay + E.TICK)
        end)

        it("buffing your own raid by hand opens no exchange and sends no plans", function()
            pair()
            wow.use(b)
            local raid = {}
            for i = 1, 10 do raid[i] = "Mem-" .. string.char(96 + i) .. "ber" end
            wow.setGroup("raid", raid)
            for i = 1, 10 do
                wow.use(b)
                wow.addUnit("target", wow.state.units["raid" .. i])
                wow.runMacro("/cast Thorns")
                advance(1.5)
            end
            wow.use(b)
            assert.are.equal(10, #wow.landed, "every buff landed")
            assert.are.same({}, plansSent(b))
            assert.are.equal(0, b.ns.Exchange.Count())
        end)

        it("nor does a buff on yourself, whichever way the game names you", function()
            pair()
            wow.use(a)
            wow.state.sentTargetForm = "full"
            wow.addUnit("target", wow.state.units.player)
            wow.runMacro("/cast Power Word: Fortitude")
            settle()
            wow.use(a)
            assert.are.equal("Ann-Vale", wow.landed[1].target, "a self-buff")
            advance(E.TICK + 0.5)
            assert.are.same({}, plansSent(a))
            assert.are.equal(0, a.ns.Exchange.Count())
        end)

        it("nor does a buff to someone when the game won't say who is in your group", function()
            pair()
            wow.use(a)
            wow.setGroup("party", { "Cid-Rock" })
            wow.state.units.party1.secrets = { name = true }
            handCast(a, "Power Word: Fortitude")
            advance(E.TICK + 0.5)
            assert.are.same({}, plansSent(a))
        end)

        it("a held /say and /thank wait no longer for a key press than they would unheld", function()
            pair({ db = { thankStyle = "both" } })
            handCast(a, "Power Word: Fortitude")
            local firstAt = wow.now
            advance(E.MAX_DELAY + E.TICK)
            wow.use(b)
            local limit = firstAt + b.ns.db.buff.delay + b.ns.BuffTracker.SAY_MAX_AGE
            assert.is_true(wow.now < limit, "released before the limit")
            advance(limit - wow.now + 0.5)
            wow.use(b)
            wow.keyDown()
            assert.are.same({}, wow.sentTo("SAY"), "released at the longest wait, then too old to say")
            assert.are.same({}, wow.emotes)
            local entries = b.ns.db.ledger.entries
            assert.are.equal("no key press in time", entries[#entries].note)
        end)

        it("but a /say released early still waits for a key press until then", function()
            pair({ db = { thankStyle = "message" } })
            handCast(a, "Power Word: Fortitude")
            local firstAt = wow.now
            press(b, "RightButton") -- let go: nothing holds it
            advance(b.ns.db.buff.delay + b.ns.BuffTracker.SAY_MAX_AGE - 2)
            assert.are.same({}, wow.sentTo("SAY"))
            wow.use(b)
            wow.keyDown()
            assert.are.equal(1, #wow.sentTo("SAY"))
            assert.is_true(wow.now - firstAt < b.ns.db.buff.delay + b.ns.BuffTracker.SAY_MAX_AGE)
        end)

        it("a player who walks off mid-exchange is thanked once, without waiting for a buff back", function()
            pair()
            handCast(a, "Power Word: Fortitude")
            advance(2)
            wow.use(b)
            wow.state.units.nameplate1, wow.state.units.target = nil, nil
            advance(E.HOLD_CAP)
            assert.are.equal(1, #thanks(b), "the button can't hold her, so it's done")
            advance(E.MAX_DELAY)
            assert.are.equal(1, #thanks(b))
        end)

        it("a player whose copy logs off mid-exchange is thanked once, within the longest wait", function()
            pair()
            handCast(a, "Power Word: Fortitude")
            local firstAt = wow.now
            net.clients = { b } -- Ann is gone: nothing more from her copy
            advance(E.MAX_DELAY + E.TICK)
            assert.are.equal(1, #thanks(b))
            assert.is_true(thanks(b)[1].time <= firstAt + E.MAX_DELAY + E.TICK)
        end)

        it("too many exchanges at once: the oldest goes, and the thank-you it held goes out", function()
            pair({ noComm = true })
            handCast(a, "Power Word: Fortitude")
            advance(b.ns.db.buff.delay + 0.5)
            assert.are.same({}, thanks(b), "held: his button is armed for her")
            wow.use(b)
            local at = wow.now
            for i = 1, E.MAX_EXCHANGES do
                local token = "nameplate" .. (i + 1)
                local surname = "Far" .. string.char(96 + math.floor((i - 1) / 26) + 1, 96 + (i - 1) % 26 + 1)
                wow.addUnit(token, { name = "Zed", surname = surname, class = "MAGE", id = "Zed-" .. surname })
                wow.gainBuff({ sourceUnit = token, name = "Arcane Intellect", spellId = 10157 })
            end
            local toAnn = {}
            for _, t in ipairs(thanks(b)) do if t.target == "Ann-Vale" then toAnn[#toAnn + 1] = t end end
            assert.are.equal(1, #toAnn, "Ann's exchange went first, and her thank-you with it")
            assert.are.equal(at, toAnn[1].time)
            assert.are.equal(E.MAX_EXCHANGES, b.ns.Exchange.Count())
        end)

        it("an error queueing one thank-you doesn't keep the others back", function()
            pair({ noComm = true, db = { delay = 0 } })
            wow.use(b)
            b.ns.db.buffBack.enabled = false
            -- The first thank-you queued fails.
            local push, failed = b.ns.ChatQueue.Push, false
            b.ns.ChatQueue.Push = function(item)
                if not failed then
                    failed = true
                    error("boom")
                end
                return push(item)
            end
            -- Two thank-yous held together, by the settle after their buffs.
            handCast(a, "Power Word: Fortitude")
            wow.use(b)
            wow.addUnit("nameplate2", { name = "Cid", surname = "Rock", class = "WARRIOR", id = "Cid-Rock" })
            wow.gainBuff({ sourceUnit = "nameplate2", name = "Arcane Intellect", spellId = 10157 })
            assert.are.same({}, thanks(b), "held")
            advance(E.SETTLE + E.TICK)
            wow.use(b)
            b.ns.ChatQueue.Push = push
            assert.is_true(failed)
            assert.are.equal(1, count(b.ns, "luaErrors"))
            assert.are.equal(1, #thanks(b), "the other one went")
            wow.errors = {}
        end)

        it("a clock that goes backwards lets a held thank-you go at their next buff, once", function()
            pair()
            advance(30) -- well past logging in, even 10 seconds back
            handCast(a, "Power Word: Fortitude")
            advance(b.ns.db.buff.delay + 1)
            assert.are.same({}, thanks(b), "held: his button is armed")
            wow.use(b)
            wow.now = wow.now - 10
            handCast(a, "Divine Spirit")
            wow.use(b)
            local at = wow.now
            advance(E.TICK)
            assert.are.equal(1, #thanks(b))
            assert.are.equal("Thanks Ann: Power Word: Fortitude and Divine Spirit", thanks(b)[1].text)
            assert.is_true(thanks(b)[1].time <= at + E.TICK)
            advance(E.MAX_DELAY + 10)
            assert.are.equal(1, #thanks(b))
        end)
    end)

    -- Red: a storm of hand casts, presses, favours let go, players walking
    -- off and back, and time passing, between two clients whose addon
    -- messages are lost at random and arrive late. The invariant comes from
    -- the simulated clients alone (wow.landed and wow.sent): between two
    -- thank-yous from one side, an exchange must have ended (a gap of GAP
    -- seconds with no buff either way, ending after the first thank-you),
    -- and a buff from the other side must have come after that gap.
    local SPELLS = { [1] = { "Power Word: Fortitude", "Divine Spirit", "Shadow Protection" },
        [2] = { "Mark of the Wild", "Thorns" } }
    local JUMPS = { 0.5, 1, 2, 3, 5, 9, 12, 31 }

    local function storm(seed)
        random.seed(seed)
        pair({ db = { repeatCooldown = 0 } })
        lag = function() return random.random(0, 3) end
        net.lose = function() return random.random() < 0.3 end
        local other = { [a] = b, [b] = a }
        local reach = { thanks = 0, maxDelay = 0, newExchanges = 0, lost = 0 }
        local lose = net.lose
        net.lose = function(...)
            local lost = lose(...)
            if lost then reach.lost = reach.lost + 1 end
            return lost
        end
        -- Every buff between the two, either way: { at, from }.
        local function buffs()
            local all = {}
            for _, c in ipairs({ a, b }) do
                wow.use(c)
                for _, l in ipairs(wow.landed) do
                    if l.target == other[c].full then all[#all + 1] = { at = l.at, from = c } end
                end
            end
            table.sort(all, function(x, y) return x.at < y.at end)
            return all
        end
        local lastThanks = { [a] = nil, [b] = nil }
        local seen = { [a] = 0, [b] = 0 }
        local function check(where)
            for _, c in ipairs({ a, b }) do
                local sent = thanks(c)
                for i = seen[c] + 1, #sent do
                    local t = sent[i]
                    assert.are.equal(other[c].full, t.target, where)
                    reach.thanks = reach.thanks + 1
                    local prev = lastThanks[c]
                    if prev then
                        -- A gap of GAP with no buff either way, ending after the
                        -- first thank-you, then a buff from the other side, all
                        -- before the second.
                        local ok, gapEnded, last = false, false, nil
                        for _, buff in ipairs(buffs()) do
                            if buff.at > t.time then break end
                            if last and buff.at > prev and buff.at - last >= c.ns.Exchange.GAP then
                                gapEnded = true
                            end
                            if gapEnded and buff.from == other[c] then ok = true end
                            last = buff.at
                        end
                        assert.is_true(ok, where .. ": " .. c.full .. " thanked twice in one exchange")
                        reach.newExchanges = reach.newExchanges + 1
                    end
                    -- The longest wait: some buff from them landed within it.
                    local recent = false
                    for _, buff in ipairs(buffs()) do
                        if buff.from == other[c] and buff.at <= t.time
                            and t.time - buff.at <= c.ns.Exchange.MAX_DELAY + c.ns.Exchange.TICK then
                            recent = true
                        end
                        if buff.from == other[c] and t.time - buff.at >= c.ns.Exchange.MAX_DELAY - 1
                            and t.time - buff.at <= c.ns.Exchange.MAX_DELAY + c.ns.Exchange.TICK then
                            reach.maxDelay = reach.maxDelay + 1
                        end
                    end
                    assert.is_true(recent, where .. ": a thank-you long after any buff")
                    lastThanks[c] = t.time
                end
                seen[c] = #sent
            end
        end
        for step = 1, 120 do
            local x = random.random() < 0.5 and a or b
            local roll = random.random()
            local mine = SPELLS[x == a and 1 or 2]
            wow.use(x)
            local visible = wow.state.units.nameplate1 ~= nil
            if roll < 0.3 and visible then
                handCast(x, mine[random.random(#mine)])
            elseif roll < 0.3 then
                advance(1) -- they walked off: nobody to target
            elseif roll < 0.5 then
                press(x)
            elseif roll < 0.55 then
                press(x, "RightButton")
            elseif roll < 0.6 then
                wow.use(x)
                if wow.state.units.nameplate1 then
                    wow.state.units.nameplate1, wow.state.units.target = nil, nil
                else
                    wow.addUnit("nameplate1", { name = other[x].name, surname = other[x].surname,
                        class = x == a and "DRUID" or "PRIEST", id = other[x].full })
                end
            else
                advance(JUMPS[random.random(#JUMPS)])
            end
            local where = string.format("seed %d step %d", seed, step)
            check(where)
            for _, c in ipairs({ a, b }) do
                wow.use(c)
                assert.are.same({}, wow.errors, where)
                assert.are.equal(0, count(c.ns, "luaErrors"), where)
            end
        end
        return reach
    end

    it("a chaos storm of exchanges with random message loss never gives two thank-yous from one side in one exchange (red)", function()
        local total = { thanks = 0, maxDelay = 0, newExchanges = 0, lost = 0 }
        for _, seed in ipairs({ 1, 2, 3, 4, 5, 6, 7, 8 }) do
            for k, v in pairs(storm(seed)) do total[k] = total[k] + v end
        end
        lag = nil
        assert.is_true(total.thanks > 40, "thank-yous were sent: " .. total.thanks)
        assert.is_true(total.newExchanges > 10, "new exchanges after a gap: " .. total.newExchanges)
        assert.is_true(total.maxDelay > 0, "some thank-yous waited the longest wait")
        assert.is_true(total.lost > 10, "messages were lost: " .. total.lost)
    end)
end)
