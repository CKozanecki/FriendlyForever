-- Spec: #37
-- Buff trading stops after one round: every buff of yours the game says went
-- to a player is remembered, however it was cast, and copies of the addon
-- mark a returned buff as "this answers yours" over the hidden channel.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local function minutes(m) return m * 60 end

local MOTW, MOTW_1, THORNS_1 = 9885, 1126, 467
local INTELLECT, INTELLECT_1 = 10157, 1459

local function count(ns, key)
    return ns.Diag.Counters()[key] or 0
end

-- The ANSWER messages this client's game accepted: { to = whisper target }.
local function answersSent()
    local out = {}
    for _, m in ipairs(wow.addonSent) do
        if m.text:find(";ANSWER;", 1, true) then out[#out + 1] = { to = m.target, route = m.channel } end
    end
    return out
end

describe("One round each way (#37)", function()
    local ns

    -- A druid who knows Mark of the Wild and Thorns; the player is Me.
    local function boot(db)
        ns = wow.boot({ db = db, before = function(state)
            state.class = "DRUID"
            state.knownSpells = { [MOTW_1] = true, [MOTW] = true, [THORNS_1] = true }
        end })
    end

    -- A stranger the game shows on a nameplate: Bob Stone unless named.
    local function stranger(token, name, surname)
        name, surname = name or "Bob", surname or "Stone"
        wow.addUnit(token or "nameplate1", { name = name, surname = surname, class = "WARRIOR", id = name .. "-" .. surname })
    end

    local function buffedBy(token)
        wow.gainBuff({ sourceUnit = token or "nameplate1", name = "Arcane Intellect", spellId = INTELLECT })
    end

    -- You target someone and cast Mark of the Wild by hand (not the button).
    local function handCast(name, surname)
        wow.addUnit("target", { name = name or "Bob", surname = surname or "Stone", class = "WARRIOR",
            id = (name or "Bob") .. "-" .. (surname or "Stone") })
        wow.runMacro("/cast Mark of the Wild")
    end

    -- The thank-you waiting for the last buff goes out (a key press), so the
    -- caster's next buff is a favour of its own rather than merged into it.
    -- Casts sent before still wait to land.
    local function apart()
        wow.advance(5)
        wow.keyDown()
        assert.are.equal(0, ns.ChatQueue.Count(), "the thank-you went")
    end

    local function owes(name)
        local offer = ns.Offers.Current()
        return offer ~= nil and offer.name == name
    end

    local function lastEntry()
        local entries = ns.db.ledger.entries
        return entries[#entries]
    end

    before_each(function() boot() end)

    describe("buffs cast by hand (white)", function()
        it("a hand-cast buff followed by their buff back means nothing is owed", function()
            stranger()
            handCast()
            assert.are.equal(1, #wow.landed, "the buff reached Bob")
            buffedBy()
            assert.are.equal(0, ns.Offers.Count())
            assert.are.equal("it answered your buff to them", lastEntry().returnNote)
        end)

        it("whichever way the game names the target: first name, or the full name", function()
            for _, form in ipairs({ "first", "full" }) do
                boot()
                wow.state.sentTargetForm = form
                stranger()
                handCast()
                buffedBy()
                assert.are.equal(0, ns.Offers.Count(), form)
            end
        end)

        it("with a player who has no surname", function()
            wow.addUnit("nameplate1", { name = "Bob", class = "WARRIOR", id = "Bob" })
            wow.addUnit("target", { name = "Bob", class = "WARRIOR", id = "Bob" })
            wow.runMacro("/cast Mark of the Wild")
            buffedBy()
            assert.are.equal(0, ns.Offers.Count())
        end)

        it("their buff back answers yours up to the end of the window, and is a new favour after it", function()
            stranger()
            handCast()
            wow.advance(ns.Offers.RETURNED_RECENTLY)
            buffedBy()
            assert.are.equal(0, ns.Offers.Count(), "at the end of the window")
            boot()
            stranger()
            handCast()
            wow.advance(ns.Offers.RETURNED_RECENTLY + 1)
            buffedBy()
            assert.is_true(owes("Bob-Stone"))
        end)

        it("a hand-cast buff to someone you owe returns their favour, and tells their copy", function()
            stranger()
            buffedBy()
            assert.is_true(owes("Bob-Stone"))
            handCast()
            assert.are.equal(0, ns.Offers.Count())
            assert.are.equal("Mark of the Wild", lastEntry().returned)
            assert.are.equal(1, ns.Ledger.Summary().returned)
            assert.are.same({ { to = "Bob-Stone", route = "WHISPER" } }, answersSent())
        end)

        it("a hand-cast buff to someone you don't owe tells nobody anything", function()
            stranger()
            handCast()
            assert.are.same({}, answersSent())
        end)

        it("the button's own return tells their copy too", function()
            stranger()
            buffedBy()
            wow.press(ns.BuffButton.Frame())
            assert.are.equal("Mark of the Wild", lastEntry().returned)
            assert.are.same({ { to = "Bob-Stone", route = "WHISPER" } }, answersSent())
        end)
    end)

    describe("unreadable or partial names (black)", function()
        -- The game's SENT and SUCCEEDED for a buff of ours, as given.
        local function sentAndLanded(targetName, guid, landedGuid)
            ns.BuffButton.OnSpellcastSent("player", targetName, guid, MOTW)
            ns.BuffButton.OnSpellcastSucceeded("player", landedGuid == nil and guid or landedGuid, MOTW)
        end

        it("an unreadable SENT target name doesn't block a real new favour", function()
            stranger()
            stranger("target")
            for i, name in ipairs({ wow.secret("Bob"), false, "", "  ", "B0b", "Bob|cff", "Bob-Stone-Hill", 42 }) do
                if name == false then name = nil end
                sentAndLanded(name, "Cast-" .. i)
            end
            buffedBy()
            assert.is_true(owes("Bob-Stone"))
            assert.are.same({}, wow.errors)
        end)

        it("nor does a cast the game names nobody for", function()
            wow.state.sentTargetForm = "none"
            stranger()
            handCast()
            buffedBy()
            assert.is_true(owes("Bob-Stone"))
        end)

        it("nor an unreadable or mismatched cast ID", function()
            stranger()
            stranger("target")
            sentAndLanded("Bob Stone", wow.secret("Cast-1"))
            sentAndLanded("Bob Stone", nil)
            sentAndLanded("Bob Stone", "Cast-2", wow.secret("Cast-2"))
            sentAndLanded("Bob Stone", "Cast-3", "Cast-4")
            buffedBy()
            assert.is_true(owes("Bob-Stone"))
        end)

        it("a first name alone stands for your target only: someone else of that name is still owed", function()
            stranger()                            -- Bob Stone, whom you buff
            stranger("nameplate2", "Bob", "Vale") -- another Bob
            handCast()
            buffedBy("nameplate2")
            assert.is_true(owes("Bob-Vale"))
            buffedBy("nameplate1")
            assert.are.equal(1, ns.Offers.Count(), "Bob Stone's buff answered yours")
        end)

        it("a first name that matches nobody you target or mouse over is not remembered", function()
            stranger() -- only on a nameplate
            sentAndLanded("Bob", "Cast-1")
            buffedBy()
            assert.is_true(owes("Bob-Stone"))
        end)

        it("a first name that isn't your target's is never pinned on your target", function()
            stranger()
            stranger("target", "Ann", "Vale")
            stranger("nameplate2", "Ann", "Vale")
            sentAndLanded("Bob", "Cast-1")
            buffedBy("nameplate2")
            assert.is_true(owes("Ann-Vale"))
        end)

        it("a first name that matches two players (target and mouseover) is not remembered", function()
            stranger()
            stranger("nameplate2", "Bob", "Vale")
            stranger("mouseover", "Bob", "Vale")
            handCast()
            buffedBy("nameplate1")
            buffedBy("nameplate2")
            assert.are.equal(2, ns.Offers.Count())
        end)

        it("a first name is matched on your target, mouseover, focus or soft target alone", function()
            for _, token in ipairs({ "target", "mouseover", "focus", "softfriend" }) do
                boot()
                stranger()
                stranger(token)
                sentAndLanded("Bob", "Cast-1")
                buffedBy()
                assert.are.equal(0, ns.Offers.Count(), token)
            end
        end)

        it("a first name you share is not remembered: a self-cast while targeting them returns nothing", function()
            wow.state.units.player.name, wow.state.units.player.surname = "Bob", "Smith"
            wow.state.units.player.id = "Bob-Smith"
            stranger()
            buffedBy()
            stranger("target")
            sentAndLanded("Bob", "Cast-1") -- the self-cast modifier: it went to you
            assert.is_true(owes("Bob-Stone"), "still owed")
            assert.is_nil(lastEntry().returned)
            assert.are.same({}, answersSent())
        end)

        it("a first name a group member shares is not remembered (an @party macro)", function()
            for _, token in ipairs({ "party4", "raid40" }) do
                boot()
                stranger()
                wow.addUnit(token, { name = "Bob", surname = "Marsh", class = "PRIEST", id = "Bob-Marsh" })
                stranger("target")
                sentAndLanded("Bob", "Cast-1")
                buffedBy()
                assert.is_true(owes("Bob-Stone"), token)
            end
        end)

        it("your target in your group is still one match", function()
            stranger()
            stranger("party1")
            handCast()
            wow.state.units.party1 = nil -- they leave your group, then buff you
            buffedBy()
            assert.are.equal(0, ns.Offers.Count())
        end)

        it("the same player on two tokens is still one match", function()
            stranger()
            stranger("focus")
            handCast()
            buffedBy()
            assert.are.equal(0, ns.Offers.Count())
        end)

        it("a buff on yourself is never remembered as one to another player", function()
            wow.addUnit("nameplate1", { name = "Me", surname = "Too", class = "WARRIOR", id = "Me-Too" })
            wow.addUnit("target", wow.state.units.player)
            sentAndLanded("Me", "Cast-1")
            buffedBy()
            assert.is_true(owes("Me-Too"), "the stranger named Me is owed")
        end)

        it("a cast that fails, or lands too late, isn't remembered", function()
            stranger()
            wow.state.castFailures["Bob-Stone"] = "Out of range"
            handCast()
            buffedBy()
            assert.is_true(owes("Bob-Stone"))
            ns.Offers.LetGo("Bob-Stone")
            apart()
            wow.state.castFailures["Bob-Stone"] = nil
            wow.state.castLatency = ns.Offers.CAST_WAIT + 1
            handCast()
            wow.advance(ns.Offers.CAST_WAIT + 2)
            assert.are.equal(1, #wow.landed)
            buffedBy()
            assert.is_true(owes("Bob-Stone"))
        end)

        it("only buffs are remembered, and only while the addon and Buff Back are on", function()
            stranger()
            stranger("target")
            ns.BuffButton.OnSpellcastSent("player", "Bob", "Cast-1", 133) -- a Fireball
            ns.BuffButton.OnSpellcastSucceeded("player", "Cast-1", 133)
            ns.db.buffBack.enabled = false
            sentAndLanded("Bob", "Cast-2")
            ns.db.buffBack.enabled = true
            ns.db.enabled = false
            sentAndLanded("Bob", "Cast-3")
            ns.db.enabled = true
            ns.BuffButton.OnSpellcastSent("player", "Bob", "Cast-4", MOTW)
            ns.db.buffBack.enabled = false -- switched off while the cast is in flight
            ns.BuffButton.OnSpellcastSucceeded("player", "Cast-4", MOTW)
            ns.db.buffBack.enabled = true
            buffedBy()
            assert.is_true(owes("Bob-Stone"))
        end)

        it("Revoke isn't a buff: it neither returns a favour nor answers one", function()
            stranger()
            stranger("target")
            buffedBy()
            ns.BuffButton.OnSpellcastSent("player", "Bob", "Cast-1", wow.REVOKE_ID)
            ns.BuffButton.OnSpellcastSucceeded("player", "Cast-1", wow.REVOKE_ID)
            assert.is_true(owes("Bob-Stone"))
            assert.is_nil(lastEntry().returned)
        end)

        it("a clock that goes backwards answers nothing", function()
            wow.advance(300) -- well past logging in, even 100 seconds back
            stranger()
            handCast()
            wow.now = wow.now - 100
            buffedBy()
            assert.is_true(owes("Bob-Stone"), "a buff from before your cast")
            ns.Offers.LetGo("Bob-Stone")
            apart()
            ns.Offers.OnAnswerMark("Bob-Stone")
            wow.now = wow.now - 10
            buffedBy()
            assert.is_true(owes("Bob-Stone"), "a buff from before the mark")
        end)

        it("another unit's cast is never yours", function()
            stranger()
            stranger("target")
            ns.Offers.OnCastSent("target", "Bob", "Cast-1", MOTW)
            ns.Offers.OnCastLanded("player", "Cast-1")
            ns.Offers.OnCastSent("player", "Bob", "Cast-2", MOTW)
            ns.Offers.OnCastLanded("target", "Cast-2")
            buffedBy()
            assert.is_true(owes("Bob-Stone"))
        end)

        it("keeps at most MAX_CASTS_WAITING casts waiting to land, the oldest going first", function()
            stranger()
            stranger("target")
            for i = 1, ns.Offers.MAX_CASTS_WAITING + 1 do
                ns.BuffButton.OnSpellcastSent("player", "Bob", "Cast-" .. i, MOTW)
            end
            ns.BuffButton.OnSpellcastSucceeded("player", "Cast-1", MOTW)
            buffedBy()
            assert.is_true(owes("Bob-Stone"), "the first cast was forgotten")
            ns.Offers.LetGo("Bob-Stone")
            apart()
            ns.BuffButton.OnSpellcastSucceeded("player", "Cast-2", MOTW)
            buffedBy()
            assert.are.equal(0, ns.Offers.Count(), "the second still waited")
        end)

        it("a cast with no readable ID takes no room from casts waiting to land", function()
            stranger()
            stranger("target")
            ns.BuffButton.OnSpellcastSent("player", "Bob", "Cast-1", MOTW)
            for _ = 1, ns.Offers.MAX_CASTS_WAITING do
                ns.BuffButton.OnSpellcastSent("player", "Bob", nil, MOTW)
                ns.BuffButton.OnSpellcastSent("player", "Bob", wow.secret("Cast-x"), MOTW)
            end
            ns.BuffButton.OnSpellcastSucceeded("player", "Cast-1", MOTW)
            buffedBy()
            assert.are.equal(0, ns.Offers.Count())
        end)

        it("remembers at most MAX_REMEMBERED players, the oldest going first", function()
            local letters = "abcdefghijklmnopqrstuvwxyz"
            local function nameOf(i)
                local a, b = math.floor((i - 1) / 26) + 1, (i - 1) % 26 + 1
                return "Pal" .. letters:sub(a, a) .. letters:sub(b, b)
            end
            local max = ns.Offers.MAX_REMEMBERED
            local function fill()
                for i = 1, max do
                    sentAndLanded(nameOf(i) .. " Stone", "Cast-" .. i)
                    wow.advance(1)
                end
            end
            fill()
            sentAndLanded(nameOf(max) .. " Stone", "Cast-again") -- someone remembered: nobody goes
            stranger("nameplate1", nameOf(1), "Stone")
            buffedBy("nameplate1")
            assert.are.equal(0, ns.Offers.Count(), "the oldest is still remembered")
            boot()
            fill()
            sentAndLanded(nameOf(max + 1) .. " Stone", "Cast-new") -- someone new: the oldest goes
            for i, token in ipairs({ "nameplate1", "nameplate2", "nameplate3" }) do
                stranger(token, nameOf(({ 1, 2, max + 1 })[i]), "Stone")
                buffedBy(token)
            end
            assert.is_true(owes(nameOf(1) .. "-Stone"), "the oldest was forgotten")
            assert.are.equal(1, ns.Offers.Count(), "the second oldest and the newest are remembered")
        end)
    end)

    describe("the \"this answers yours\" mark (black)", function()
        local function answer(sender, text, route)
            wow.fire("CHAT_MSG_ADDON", "FriendlyFvr", text or ("1;ANSWER;" .. sender), route or "WHISPER", sender,
                "", 0, 0, "", 0)
        end

        it("lets go a favour owed a moment ago for the sender's buff", function()
            stranger()
            buffedBy()
            wow.advance(ns.Offers.MARK_SECONDS - 1)
            answer("Bob-Stone")
            assert.are.equal(0, ns.Offers.Count())
            assert.are.equal("it answered your buff to them", lastEntry().returnNote)
        end)

        it("arriving first, it answers the sender's next buff only, and only for a while", function()
            stranger()
            answer("Bob-Stone")
            buffedBy()
            assert.are.equal(0, ns.Offers.Count(), "answered")
            apart() -- still within MARK_SECONDS
            buffedBy()
            assert.is_true(owes("Bob-Stone"), "one mark answers one buff")
            ns.Offers.LetGo("Bob-Stone")
            answer("Bob-Stone")
            wow.advance(ns.Offers.MARK_SECONDS + 1)
            buffedBy()
            assert.is_true(owes("Bob-Stone"), "an old mark answers nothing")
        end)

        it("lets go a favour owed up to MARK_SECONDS before it", function()
            stranger()
            buffedBy()
            wow.advance(ns.Offers.MARK_SECONDS)
            answer("Bob-Stone")
            assert.are.equal(0, ns.Offers.Count())
        end)

        it("never touches a favour owed long before it", function()
            stranger()
            buffedBy()
            wow.advance(ns.Offers.MARK_SECONDS + 1)
            answer("Bob-Stone")
            assert.is_true(owes("Bob-Stone"))
        end)

        it("only ever stops you owing the sender", function()
            stranger()
            stranger("nameplate2", "Ann", "Vale")
            buffedBy("nameplate2")
            answer("Bob-Stone")
            answer("Bob-Stone", "1;ANSWER;Ann-Vale") -- about someone else: spoofed
            assert.is_true(owes("Ann-Vale"))
            assert.are.equal(1, count(ns, "commSpoofed"))
        end)

        it("is dropped on a group route, with fields, or from another protocol version", function()
            stranger()
            buffedBy()
            answer("Bob-Stone", nil, "GUILD")
            answer("Bob-Stone", "1;ANSWER;Bob-Stone;x")
            answer("Bob-Stone", "2;ANSWER;Bob-Stone")
            assert.is_true(owes("Bob-Stone"))
            assert.are.equal(1, count(ns, "commWrongRoute"))
            assert.are.equal(1, count(ns, "commMalformed"))
            assert.are.equal(1, count(ns, "commWrongVersion"))
        end)

        it("keeps at most MAX_MARKS marks waiting, the oldest going first", function()
            local letters = "abcdefghijklmnopqrstuvwxyz"
            local function nameOf(i)
                local a, b = math.floor((i - 1) / 26) + 1, (i - 1) % 26 + 1
                return "Pal" .. letters:sub(a, a) .. letters:sub(b, b)
            end
            local n = ns.Offers.MAX_MARKS + 1
            for i = 1, n do
                ns.Offers.OnAnswerMark(nameOf(i) .. "-Stone")
                wow.advance(0.1)
            end
            stranger("nameplate1", nameOf(1), "Stone")
            stranger("nameplate2", nameOf(n), "Stone")
            buffedBy("nameplate1")
            buffedBy("nameplate2")
            assert.is_true(owes(nameOf(1) .. "-Stone"), "the oldest was forgotten")
            assert.are.equal(1, ns.Offers.Count(), "the newest still answers")
        end)
    end)
end)

describe("One round each way between two copies of the addon (#37)", function()
    local a, b, net

    -- Ann Vale, a druid, and Bo Lake, a mage, out in the world; each sees
    -- the other on a nameplate. opts.db: both clients' settings;
    -- opts.noComm: neither has addon messages.
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
            return opts.db and { buffBack = { owedMinutes = opts.db.owedMinutes } } or nil
        end
        a = wow.newClient({ name = "Ann", surname = "Vale", db = db(),
            before = setup("DRUID", { [MOTW_1] = true, [MOTW] = true },
                { name = "Bo", surname = "Lake", class = "MAGE", id = "Bo-Lake" }) })
        b = wow.newClient({ name = "Bo", surname = "Lake", db = db(),
            before = setup("MAGE", { [INTELLECT_1] = true, [INTELLECT] = true },
                { name = "Ann", surname = "Vale", class = "DRUID", id = "Ann-Vale" }) })
        net = wow.network({ a, b })
    end

    local SPELL = { ["Ann-Vale"] = "Mark of the Wild", ["Bo-Lake"] = "Arcane Intellect" }

    -- Everything sent so far reaches the other side: buffs first, then
    -- addon messages (a mark follows the cast it marks).
    local function settle()
        wow.deliverBuffs(net)
        wow.deliver(net)
    end

    -- The client targets the other and casts its buff by hand.
    local function handCast(client)
        wow.use(client)
        wow.addUnit("target", wow.state.units.nameplate1)
        wow.runMacro("/cast " .. SPELL[client.full])
        settle()
    end

    local function press(client)
        wow.use(client)
        wow.press(client.ns.BuffButton.Frame())
        settle()
    end

    local function owedBy(client)
        wow.use(client)
        return client.ns.Offers.Count()
    end

    it("the issue's story ends at two buffs: A by hand, B with the button, and A owes nothing (white)", function()
        pair()
        handCast(a)
        assert.are.equal(1, owedBy(b))
        press(b)
        assert.are.equal(0, owedBy(b))
        assert.are.equal(0, owedBy(a))
    end)

    it("without the hidden channel too, within the window (white)", function()
        pair({ noComm = true })
        handCast(a)
        wow.advanceAll(net, minutes(9), 30)
        press(b)
        assert.are.equal(0, owedBy(a))
    end)

    it("across a gap longer than the window, the mark from their copy answers yours (white)", function()
        pair({ db = { owedMinutes = 60 } })
        handCast(a)
        wow.advanceAll(net, minutes(30), 60)
        press(b)
        wow.use(b)
        assert.are.equal(1, #answersSent(), "B's copy marked its buff")
        assert.are.equal(0, owedBy(a))
    end)

    it("and without the mark, that late buff back would be owed again (white)", function()
        pair({ db = { owedMinutes = 60 }, noComm = true })
        handCast(a)
        wow.advanceAll(net, minutes(30), 60)
        press(b)
        assert.are.equal(1, owedBy(a))
    end)

    it("a hand-cast return answers too: neither side owes after one round (white)", function()
        pair({ db = { owedMinutes = 60 } })
        handCast(b)
        wow.advanceAll(net, minutes(20), 60)
        handCast(a)
        assert.are.equal(0, owedBy(a))
        assert.are.equal(0, owedBy(b))
    end)

    -- Red: a storm of hand casts, button presses,
    -- time jumps (past the window too), decoys sharing the other's first
    -- name, and the game naming targets by first or full name. The
    -- invariant is worked out from the simulated client alone: every buff
    -- that answers (a button cast, or a hand cast made while the button
    -- held that player; any other hand cast opens) is matched to an earlier opener the other way, so
    -- answers X->Y never outnumber openers Y->X. A second round would be an
    -- answer to an answer.
    local function storm(seed, opts)
        random.seed(seed)
        pair(opts)
        local openers, answers = { [a] = 0, [b] = 0 }, { [a] = 0, [b] = 0 }
        local other = { [a] = b, [b] = a }
        local DECOY = { [a] = { name = "Bo", surname = "Stone", class = "MAGE", id = "Bo-Stone" },
            [b] = { name = "Ann", surname = "Rock", class = "DRUID", id = "Ann-Rock" } }
        -- Whether the client's button holds a cast on the other.
        local function armedFor(client)
            wow.use(client)
            local frame = client.ns.BuffButton.Frame()
            local text = frame:GetAttribute(client.ns.BuffButton.SECURE_ATTRIBUTE.leftButtonMacroText)
            local o = other[client]
            return text ~= nil and text:find("/targetexact " .. o.name .. " " .. o.surname, 1, true) ~= nil
        end
        local function landedBy(client)
            wow.use(client)
            return #wow.landed
        end
        for step = 1, 120 do
            local x = random.random() < 0.5 and a or b
            local roll = random.random()
            local before = landedBy(x)
            local kind
            if roll < 0.3 then
                -- By hand: a return when the button held them, else an opener.
                -- A return the game names by first name alone with a decoy
                -- under the mouse can't be credited (the black tests cover
                -- it), so returns are made with none.
                kind = armedFor(x) and "answer" or "opener"
                if kind == "answer" then
                    wow.use(x)
                    wow.state.units.mouseover = nil
                end
                handCast(x)
            elseif roll < 0.65 then
                kind = armedFor(x) and "answer" or nil
                press(x)
            elseif roll < 0.85 then
                local jumps = { 5, 60, 400, 590, 610, 1200, 2400 }
                wow.advanceAll(net, jumps[random.random(#jumps)], 30)
            elseif roll < 0.95 and opts and opts.decoys then
                wow.use(x)
                wow.state.units.mouseover = (not wow.state.units.mouseover) and DECOY[x] or nil
            else
                wow.use(x)
                wow.state.sentTargetForm = random.random() < 0.5 and "first" or "full"
            end
            local landed = landedBy(x) - before
            assert.is_true(landed <= 1, "one cast per action")
            if landed == 1 then
                assert.is_not_nil(kind, "seed " .. seed .. " step " .. step .. ": a press cast with nothing armed")
                if kind == "opener" then openers[x] = openers[x] + 1 else answers[x] = answers[x] + 1 end
            end
            for _, c in ipairs({ a, b }) do
                assert.is_true(answers[c] <= openers[other[c]], string.format(
                    "seed %d step %d: %s answered %d times to %d openers", seed, step, c.full, answers[c],
                    openers[other[c]]))
                wow.use(c)
                assert.are.same({}, wow.errors)
                assert.are.equal(0, count(c.ns, "luaErrors"))
            end
        end
        return openers[a] + openers[b], answers[a] + answers[b]
    end

    it("a chaos storm of two clients buffing each other never goes past one round (red)", function()
        local opened, answered = 0, 0
        for seed = 1, 12 do
            local o, n = storm(seed, { db = { owedMinutes = 60 }, decoys = true })
            opened, answered = opened + o, answered + n
        end
        assert.is_true(answered > 20, "the storms returned favours: " .. answered)
        assert.is_true(opened > 20, "the storms opened favours: " .. opened)
    end)

    it("nor without the hidden channel, with favours kept no longer than the window (red)", function()
        local answered = 0
        for seed = 101, 108 do
            local _, n = storm(seed, { noComm = true })
            answered = answered + n
        end
        assert.is_true(answered > 10, "the storms returned favours: " .. answered)
    end)
end)
