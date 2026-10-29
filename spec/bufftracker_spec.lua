-- Spec: #99
local wow = require("spec.support.wow")

describe("Buff thanks", function()
    local ns

    local function boot(dbBuff)
        ns = wow.boot({ db = dbBuff and { buff = dbBuff } or nil })
        -- Only the first message: deterministic text in assertions.
        ns.db.buff.messages = { "Thank you for the {buff}, {name}!" }
    end

    -- Advance past the delay and press a key so a waiting /say goes out.
    local function settle()
        wow.advance(ns.db.buff.delay + 0.01)
        wow.keyDown()
    end

    local function stranger(token, name)
        wow.addUnit(token or "target", { name = name or "Bob" })
    end

    -- A stranger whose target is us, so their casts can name a buff's caster.
    local function buffer(token, name)
        wow.addUnit(token, { name = name, target = "player" })
    end

    local function logHas(fragment)
        for _, line in ipairs(ns.db.diagLog) do
            if line:find(fragment, 1, true) then return true end
        end
        return false
    end

    before_each(function() boot() end)

    describe("thanks someone outside the group", function()
        it("in /say, after the delay and a key press", function()
            stranger()
            wow.gainBuff({ sourceUnit = "target", name = "Arcane Intellect", spellId = 1459 })
            wow.advance(ns.db.buff.delay - 1)
            wow.keyDown()
            assert.are.equal(0, #wow.sent, "not before the delay")
            settle()
            assert.are.same({ "Thank you for the Arcane Intellect, Bob!" }, wow.sentTo("SAY"))
        end)

        it("for a buff that was just cast (it has a duration)", function()
            stranger()
            wow.gainBuff({ sourceUnit = "target", name = "Arcane Intellect", duration = 1800,
                expirationTime = wow.now + 1800 })
            settle()
            assert.are.same({ "Thank you for the Arcane Intellect, Bob!" }, wow.sentTo("SAY"))
        end)

        it("when the buff's timing is secret (can't tell its age)", function()
            stranger()
            wow.gainBuff({ sourceUnit = "target", name = "Arcane Intellect",
                duration = wow.secret(1800), expirationTime = wow.secret(wow.now + 100) })
            settle()
            assert.are.same({ "Thank you for the Arcane Intellect, Bob!" }, wow.sentTo("SAY"))
        end)

        it("identified by nameplate", function()
            stranger("nameplate7", "Alice")
            wow.gainBuff({ sourceUnit = "nameplate7", name = "Mark of the Wild" })
            settle()
            assert.are.same({ "Thank you for the Mark of the Wild, Alice!" }, wow.sentTo("SAY"))
        end)
    end)

    describe("never thanks", function()
        it("group members", function()
            wow.state.groupType = "party"
            wow.state.groupMembers.Pal = true
            wow.addUnit("party1", { name = "Pal" })
            wow.gainBuff({ sourceUnit = "party1", name = "Fort" })
            settle()
            assert.are.equal(0, #wow.sent)
        end)

        it("raid members", function()
            wow.state.groupType = "raid"
            wow.state.groupMembers.Pal = true
            wow.addUnit("raid12", { name = "Pal" })
            wow.gainBuff({ sourceUnit = "raid12", name = "Fort" })
            settle()
            assert.are.equal(0, #wow.sent)
        end)

        it("myself or my pet", function()
            wow.addUnit("pet", { name = "Fluffy", isPlayer = false })
            wow.gainBuff({ sourceUnit = "player", name = "Food" })
            wow.gainBuff({ sourceUnit = "pet", name = "Pet buff" })
            settle()
            assert.are.equal(0, #wow.sent)
        end)

        it("NPCs and hostile players", function()
            wow.addUnit("target", { name = "Guard", isPlayer = false })
            wow.addUnit("nameplate1", { name = "Enemy", hostile = true })
            wow.gainBuff({ sourceUnit = "target", name = "Blessing" })
            wow.gainBuff({ sourceUnit = "nameplate1", name = "Odd" })
            settle()
            assert.are.equal(0, #wow.sent)
        end)

        it("debuffs", function()
            stranger()
            wow.gainBuff({ sourceUnit = "target", name = "Curse", isHelpful = false })
            settle()
            assert.are.equal(0, #wow.sent)
        end)

        it("buffs present when logging in or zoning (full update)", function()
            stranger()
            wow.fire("UNIT_AURA", "player", { isFullUpdate = true })
            settle()
            assert.are.equal(0, #wow.sent)
        end)

        -- In-game: after a disconnect the loading screen hung for ~50s, past
        -- the login grace period, and Mark of the Wild and Blessing of Might
        -- from before the drop were thanked in /say as if new.
        it("buffs I already had, re-sent after a slow loading screen (the in-game bug)", function()
            ns = wow.boot({ noGrace = true })
            wow.advance(60) -- stuck loading, grace long over
            wow.gainBuffs({
                { name = "Mark of the Wild", spellId = 6756, duration = 1800, expirationTime = wow.now + 900 },
                { name = "Blessing of Might", spellId = 19740, duration = 300, expirationTime = wow.now + 120 },
            })
            settle()
            assert.are.equal(0, #wow.sent)
        end)

        it("a buff cast a while ago, even outside a login", function()
            stranger()
            wow.gainBuff({ sourceUnit = "target", name = "Arcane Intellect", duration = 1800,
                expirationTime = wow.now + 1800 - (ns.BuffTracker.STALE_AFTER + 1) })
            settle()
            assert.are.equal(0, #wow.sent)
        end)

        it("during the login grace period", function()
            ns = wow.boot({ noGrace = true })
            stranger()
            wow.gainBuff({ sourceUnit = "target", name = "Fort" })
            wow.advance(30)
            wow.keyDown()
            assert.are.equal(0, #wow.sent)
        end)

        it("when buff thanks or the whole addon is off", function()
            stranger()
            ns.db.buff.enabled = false
            wow.gainBuff({ sourceUnit = "target", name = "Fort" })
            ns.db.buff.enabled = true
            ns.db.enabled = false
            wow.gainBuff({ sourceUnit = "target", name = "Int" })
            settle()
            assert.are.equal(0, #wow.sent)
        end)

        it("if switched off while the thank-you was waiting", function()
            stranger()
            wow.gainBuff({ sourceUnit = "target", name = "Fort" })
            wow.advance(ns.db.buff.delay + 0.01)
            ns.db.buff.enabled = false
            wow.keyDown()
            assert.are.equal(0, #wow.sent)
        end)
    end)

    describe("several buffs from one person", function()
        it("are thanked once, listing every buff", function()
            stranger()
            wow.gainBuff({ sourceUnit = "target", name = "Power Word: Fortitude" })
            wow.advance(1)
            wow.gainBuff({ sourceUnit = "target", name = "Divine Spirit" })
            wow.advance(1)
            wow.gainBuff({ sourceUnit = "target", name = "Shadow Protection" })
            settle()
            assert.are.same(
                { "Thank you for the Power Word: Fortitude, Divine Spirit and Shadow Protection, Bob!" },
                wow.sentTo("SAY"))
        end)

        it("arriving in one update are thanked once", function()
            stranger()
            wow.gainBuffs({
                { sourceUnit = "target", name = "A" },
                { sourceUnit = "target", name = "B" },
            })
            settle()
            assert.are.same({ "Thank you for the A and B, Bob!" }, wow.sentTo("SAY"))
        end)

        it("keep merging while the /say waits for a key press", function()
            stranger()
            wow.gainBuff({ sourceUnit = "target", name = "A" })
            wow.advance(ns.db.buff.delay + 5)
            wow.gainBuff({ sourceUnit = "target", name = "B" })
            wow.keyDown()
            assert.are.same({ "Thank you for the A and B, Bob!" }, wow.sentTo("SAY"))
        end)

        it("list the same buff only once", function()
            stranger()
            wow.gainBuff({ sourceUnit = "target", name = "A" })
            wow.gainBuff({ sourceUnit = "target", name = "A" })
            settle()
            assert.are.same({ "Thank you for the A, Bob!" }, wow.sentTo("SAY"))
        end)

        it("say 'buffs' instead of names when listing is off", function()
            ns.db.buff.listBuffNames = false
            stranger()
            wow.gainBuffs({ { sourceUnit = "target", name = "A" }, { sourceUnit = "target", name = "B" } })
            settle()
            assert.are.same({ "Thank you for the buffs, Bob!" }, wow.sentTo("SAY"))
        end)

        it("say 'buff' for a single buff when listing is off", function()
            ns.db.buff.listBuffNames = false
            stranger()
            wow.gainBuff({ sourceUnit = "target", name = "A" })
            settle()
            assert.are.same({ "Thank you for the buff, Bob!" }, wow.sentTo("SAY"))
        end)
    end)

    describe("repeat cooldown", function()
        it("doesn't thank the same person again within it (default 3 minutes)", function()
            stranger()
            wow.gainBuff({ sourceUnit = "target", name = "A" })
            settle()
            wow.advance(170)
            wow.gainBuff({ sourceUnit = "target", name = "A" })
            settle()
            assert.are.equal(1, #wow.sent)
        end)

        it("thanks them again after it", function()
            stranger()
            wow.gainBuff({ sourceUnit = "target", name = "A" })
            settle()
            wow.advance(181)
            wow.gainBuff({ sourceUnit = "target", name = "A" })
            settle()
            assert.are.equal(2, #wow.sent)
        end)

        it("is configurable", function()
            ns.db.buff.repeatCooldown = 10
            stranger()
            wow.gainBuff({ sourceUnit = "target", name = "A" })
            settle()
            wow.advance(11)
            wow.gainBuff({ sourceUnit = "target", name = "A" })
            settle()
            assert.are.equal(2, #wow.sent)
        end)

        it("is per person", function()
            stranger("target", "Bob")
            stranger("nameplate2", "Alice")
            wow.gainBuff({ sourceUnit = "target", name = "A" })
            wow.gainBuff({ sourceUnit = "nameplate2", name = "B" })
            settle()
            wow.advance(2)
            wow.keyDown()
            assert.are.equal(2, #wow.sent)
        end)
    end)

    describe("caster found from a recent cast", function()
        it("when the aura doesn't name its caster", function()
            buffer("mouseover", "Carol")
            wow.fire("UNIT_SPELLCAST_SUCCEEDED", "mouseover", "cast-guid", 1459)
            wow.gainBuff({ name = "Arcane Intellect", spellId = 1459, isFromPlayerOrPlayerPet = true })
            settle()
            assert.are.same({ "Thank you for the Arcane Intellect, Carol!" }, wow.sentTo("SAY"))
        end)

        it("not when the cast was too long ago", function()
            ns.db.buff.fallbackToSay = false
            buffer("mouseover", "Carol")
            wow.fire("UNIT_SPELLCAST_SUCCEEDED", "mouseover", "cast-guid", 1459)
            wow.advance(ns.BuffTracker.CAST_MATCH_WINDOW + 1)
            wow.gainBuff({ name = "Arcane Intellect", spellId = 1459 })
            settle()
            assert.are.equal(0, #wow.sent)
        end)

        it("never from a group member's cast", function()
            wow.state.groupType = "party"
            wow.state.groupMembers.Pal = true
            wow.addUnit("target", { name = "Pal" })
            wow.fire("UNIT_SPELLCAST_SUCCEEDED", "target", "g", 1459)
            wow.gainBuff({ name = "Arcane Intellect", spellId = 1459 })
            settle()
            assert.are.equal(0, #wow.sent, "group member's cast is not mistaken for a stranger")
        end)

        -- Codebase review B3: in a city, Alice buffs Dave and Bob, whom the
        -- game can't name, buffs us with the same spell. Alice's cast isn't
        -- remembered, so Bob's buff gets the usual "friend" fallback.
        local function aliceBuffsDave()
            wow.addUnit("nameplate2", { name = "Dave" })
            wow.addUnit("nameplate7", { name = "Alice", target = "nameplate2" })
            wow.fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate7", "g", 1459)
            wow.advance(0.5)
            wow.gainBuff({ name = "Arcane Intellect", spellId = 1459, isFromPlayerOrPlayerPet = true })
            settle()
        end

        it("not from a cast aimed at someone else: Bob's buff is thanked as 'friend', not Alice", function()
            aliceBuffsDave()
            assert.are.same({ "Thank you for the Arcane Intellect, friend!" }, wow.sentTo("SAY"))
            assert.are.equal(1, #wow.sent)
        end)

        it("not from a cast aimed at someone else, with the /say fallback off: nobody is thanked", function()
            ns.db.buff.fallbackToSay = false
            aliceBuffsDave()
            assert.are.equal(0, #wow.sent)
        end)

        it("not from a cast aimed at someone else, while grouped: nobody is thanked", function()
            wow.state.groupType = "party"
            aliceBuffsDave()
            assert.are.equal(0, #wow.sent)
        end)

        it("not from a cast aimed at someone else, in a battleground (instance group): nobody is thanked", function()
            wow.state.groupType = "instance"
            wow.state.inInstance = true
            aliceBuffsDave()
            assert.are.equal(0, #wow.sent)
        end)

        it("a cast aimed at someone else doesn't replace an earlier one aimed at you", function()
            buffer("nameplate3", "Bob")
            wow.addUnit("nameplate2", { name = "Dave" })
            wow.addUnit("nameplate7", { name = "Alice", target = "nameplate2" })
            wow.fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate3", "g", 1459)
            wow.advance(0.2)
            wow.fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate7", "g", 1459)
            wow.gainBuff({ name = "Arcane Intellect", spellId = 1459 })
            settle()
            assert.are.same({ "Thank you for the Arcane Intellect, Bob!" }, wow.sentTo("SAY"))
        end)

        it("from a cast aimed at you, by nameplate", function()
            buffer("nameplate7", "Alice")
            wow.fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate7", "g", 1459)
            wow.advance(0.5)
            wow.gainBuff({ name = "Arcane Intellect", spellId = 1459 })
            settle()
            assert.are.same({ "Thank you for the Arcane Intellect, Alice!" }, wow.sentTo("SAY"))
        end)

        it("not when the caster's target is secret: 'friend' is thanked instead", function()
            wow.addUnit("nameplate7", { name = "Alice", target = "player", targetUnreadable = true })
            wow.fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate7", "g", 1459)
            wow.gainBuff({ name = "Arcane Intellect", spellId = 1459, isFromPlayerOrPlayerPet = true })
            settle()
            assert.are.same({ "Thank you for the Arcane Intellect, friend!" }, wow.sentTo("SAY"))
            assert.are.equal(1, #wow.sent)
        end)

        it("not when the game gives no answer about the caster's target: 'friend' is thanked instead", function()
            buffer("nameplate7", "Alice")
            local isUnit = _G.UnitIsUnit
            _G.UnitIsUnit = function(a, b)
                if a == "nameplate7target" then return nil end
                return isUnit(a, b)
            end
            wow.fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate7", "g", 1459)
            wow.gainBuff({ name = "Arcane Intellect", spellId = 1459, isFromPlayerOrPlayerPet = true })
            settle()
            assert.are.same({ "Thank you for the Arcane Intellect, friend!" }, wow.sentTo("SAY"))
            assert.are.equal(1, #wow.sent)
        end)

        it("ignores casts from group unit tokens", function()
            ns.db.buff.fallbackToSay = false
            wow.addUnit("party1", { name = "Pal", inParty = false })
            wow.fire("UNIT_SPELLCAST_SUCCEEDED", "party1", "g", 1459)
            wow.gainBuff({ name = "Arcane Intellect", spellId = 1459 })
            settle()
            assert.are.equal(0, #wow.sent)
        end)
    end)

    describe("a caster whose name hasn't loaded ('Unknown')", function()
        it("owes no favour and isn't thanked by that name", function()
            ns.db.buffBack.enabled = true
            wow.addUnit("target", { name = "Bob", nameLoading = true })
            wow.gainBuff({ sourceUnit = "target", name = "Arcane Intellect", spellId = 1459 })
            settle()
            assert.are.equal(0, ns.Offers.Count())
            assert.are.same({}, wow.sentTo("SAY"))
            assert.are.same({}, wow.sentTo("WHISPER"))
        end)

        it("owes no favour when found from a recent cast either: thanked as 'friend'", function()
            ns.db.buffBack.enabled = true
            wow.addUnit("nameplate7", { name = "Alice", target = "player", nameLoading = true })
            wow.fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate7", "cast-1", 1459)
            wow.gainBuff({ name = "Arcane Intellect", spellId = 1459 })
            settle()
            assert.are.equal(0, ns.Offers.Count())
            assert.are.same({ "Thank you for the Arcane Intellect, friend!" }, wow.sentTo("SAY"),
                "an unidentified player, not 'Unknown'")
        end)
    end)

    describe("unknown caster", function()
        it("is thanked as 'friend' in /say", function()
            wow.gainBuff({ name = "Arcane Intellect", isFromPlayerOrPlayerPet = true })
            settle()
            assert.are.same({ "Thank you for the Arcane Intellect, friend!" }, wow.sentTo("SAY"))
        end)

        it("uses the configured name", function()
            ns.db.buff.unknownName = "kind stranger"
            wow.gainBuff({ name = "A" })
            settle()
            assert.are.same({ "Thank you for the A, kind stranger!" }, wow.sentTo("SAY"))
        end)

        it("falls back to 'friend' if the name is left blank", function()
            ns.db.buff.unknownName = ""
            wow.gainBuff({ name = "A" })
            settle()
            assert.are.same({ "Thank you for the A, friend!" }, wow.sentTo("SAY"))
        end)

        it("isn't thanked when the /say fallback is switched off", function()
            ns.db.buff.fallbackToSay = false
            wow.gainBuff({ name = "A" })
            settle()
            assert.are.equal(0, #wow.sent)
        end)

        it("is not thanked for buffs that didn't come from a player", function()
            wow.gainBuff({ name = "Zone buff", isFromPlayerOrPlayerPet = false })
            settle()
            assert.are.equal(0, #wow.sent)
        end)

        it("buffs within a moment are merged into one thank-you", function()
            wow.gainBuff({ name = "A" })
            wow.advance(1)
            wow.gainBuff({ name = "B" })
            settle()
            assert.are.same({ "Thank you for the A and B, friend!" }, wow.sentTo("SAY"))
        end)

        it("is thanked at most once per short cooldown", function()
            wow.gainBuff({ name = "A" })
            settle()
            wow.advance(5)
            wow.gainBuff({ name = "B" })
            settle()
            assert.are.equal(1, #wow.sent)
            wow.advance(ns.BuffTracker.UNKNOWN_COOLDOWN)
            wow.gainBuff({ name = "C" })
            settle()
            assert.are.equal(2, #wow.sent)
        end)
    end)

    describe("while in a group (totems, auras, shouts)", function()
        local function joinGroup(groupType)
            wow.state.groupType = groupType or "party"
            wow.state.groupMembers.Shammy = true
            wow.addUnit("party1", { name = "Shammy" })
        end

        it("doesn't thank 'friend' for a groupmate's totem with no caster unit", function()
            joinGroup()
            wow.gainBuff({ name = "Strength of Earth", spellId = 8076, isFromPlayerOrPlayerPet = true })
            settle()
            assert.are.equal(0, #wow.sent)
        end)

        it("stays quiet as totem buffs re-apply walking in and out of range", function()
            joinGroup()
            for _ = 1, 10 do
                wow.gainBuff({ name = "Strength of Earth", isFromPlayerOrPlayerPet = true })
                wow.advance(ns.BuffTracker.UNKNOWN_COOLDOWN + 5)
                wow.keyDown()
            end
            assert.are.equal(0, #wow.sent)
        end)

        it("doesn't thank in a raid either", function()
            joinGroup("raid")
            wow.gainBuff({ name = "Windfury Totem" })
            settle()
            assert.are.equal(0, #wow.sent)
        end)

        it("doesn't thank a totem reported as its own (non-player) caster", function()
            joinGroup()
            wow.addUnit("nameplate3", { name = "Strength of Earth Totem", isPlayer = false })
            wow.gainBuff({ sourceUnit = "nameplate3", name = "Strength of Earth" })
            settle()
            assert.are.equal(0, #wow.sent)
        end)

        it("doesn't thank a totem reported with the shaman as caster", function()
            joinGroup()
            wow.gainBuff({ sourceUnit = "party1", name = "Strength of Earth" })
            settle()
            assert.are.equal(0, #wow.sent)
        end)

        it("still thanks a stranger the game names", function()
            joinGroup()
            stranger("target", "Bob")
            wow.gainBuff({ sourceUnit = "target", name = "Arcane Intellect" })
            settle()
            assert.are.same({ "Thank you for the Arcane Intellect, Bob!" }, wow.sentTo("SAY"))
        end)

        it("still thanks a stranger found from a recent cast", function()
            joinGroup()
            buffer("mouseover", "Carol")
            wow.fire("UNIT_SPELLCAST_SUCCEEDED", "mouseover", "g", 1459)
            wow.gainBuff({ name = "Arcane Intellect", spellId = 1459 })
            settle()
            assert.are.same({ "Thank you for the Arcane Intellect, Carol!" }, wow.sentTo("SAY"))
        end)

        it("uses the 'friend' fallback again after leaving the group", function()
            joinGroup()
            wow.gainBuff({ name = "Strength of Earth" })
            settle()
            assert.are.equal(0, #wow.sent)
            wow.state.groupType = nil
            wow.state.groupMembers = {}
            wow.gainBuff({ name = "Arcane Intellect" })
            settle()
            assert.are.same({ "Thank you for the Arcane Intellect, friend!" }, wow.sentTo("SAY"))
        end)
    end)

    describe("a /say thank-you nobody presses a key for", function()
        it("is dropped once it has waited longer than its own limit, and logged", function()
            ns.db.debug = true
            stranger()
            wow.gainBuff({ sourceUnit = "target", name = "Fort" })
            wow.advance(ns.db.buff.delay + ns.BuffTracker.SAY_MAX_AGE + ns.ChatQueue.RETRY_DELAY + 1)
            assert.are.equal(0, ns.ChatQueue.Count())
            wow.keyDown()
            assert.are.equal(0, #wow.sent)
            assert.is_true(logHas("dropped buff for Bob: waited too long (" .. ns.BuffTracker.SAY_MAX_AGE .. "s)"))
        end)

        it("still goes out within that limit", function()
            stranger()
            wow.gainBuff({ sourceUnit = "target", name = "Fort" })
            wow.advance(ns.db.buff.delay + ns.BuffTracker.SAY_MAX_AGE - 1)
            wow.keyDown()
            assert.are.same({ "Thank you for the Fort, Bob!" }, wow.sentTo("SAY"))
        end)
    end)

    describe("whisper instead of say", function()
        before_each(function() ns.db.buff.useWhisper = true end)

        it("whispers the caster without needing a key press", function()
            stranger()
            wow.gainBuff({ sourceUnit = "target", name = "Fort" })
            wow.advance(ns.db.buff.delay + 0.01)
            assert.are.equal(1, #wow.sent)
            assert.are.equal("WHISPER", wow.sent[1].channel)
            assert.are.equal("Bob", wow.sent[1].target)
            assert.are.equal("Thank you for the Fort, Bob!", wow.sent[1].text)
            assert.are.equal(0, #wow.sentTo("SAY"))
        end)

        it("thanks a caster it can't name as 'friend' in /say instead", function()
            wow.gainBuff({ name = "Fort" })
            settle()
            assert.are.same({ "Thank you for the Fort, friend!" }, wow.sentTo("SAY"))
            assert.are.equal(0, #wow.sentTo("WHISPER"))
        end)

        it("doesn't thank a caster it can't name when the /say fallback is off", function()
            ns.db.buff.fallbackToSay = false
            wow.gainBuff({ name = "Fort" })
            settle()
            assert.are.equal(0, #wow.sent)
        end)

        it("thanks in /say as 'friend' when the game can't deliver the whisper", function()
            stranger()
            wow.gainBuff({ sourceUnit = "target", name = "Fort" })
            wow.gainBuff({ sourceUnit = "target", name = "Int" })
            wow.advance(ns.db.buff.delay + 0.01)
            assert.are.equal("WHISPER", wow.sent[1].channel)
            wow.systemMessage("No player named 'Bob' is currently playing.")
            settle()
            assert.are.same({ "Thank you for the Fort and Int, friend!" }, wow.sentTo("SAY"))
        end)

        it("doesn't fall back for a failed whisper when the /say fallback is off", function()
            ns.db.buff.fallbackToSay = false
            stranger()
            wow.gainBuff({ sourceUnit = "target", name = "Fort" })
            wow.advance(ns.db.buff.delay + 0.01)
            wow.systemMessage("No player named 'Bob' is currently playing.")
            settle()
            assert.are.equal(0, #wow.sentTo("SAY"))
        end)

        it("ignores 'no player named' replies that aren't about our whisper", function()
            stranger()
            wow.gainBuff({ sourceUnit = "target", name = "Fort" })
            wow.advance(ns.db.buff.delay + 0.01)
            wow.systemMessage("No player named 'Someone' is currently playing.")
            settle()
            assert.are.equal(0, #wow.sentTo("SAY"))
        end)

        it("ignores a failure reply that comes long after the whisper", function()
            stranger()
            wow.gainBuff({ sourceUnit = "target", name = "Fort" })
            wow.advance(ns.db.buff.delay + 0.01)
            wow.advance(ns.BuffTracker.WHISPER_FAIL_WINDOW + 1)
            wow.systemMessage("No player named 'Bob' is currently playing.")
            settle()
            assert.are.equal(0, #wow.sentTo("SAY"))
        end)

        it("falls back only once per failed whisper", function()
            stranger()
            wow.gainBuff({ sourceUnit = "target", name = "Fort" })
            wow.advance(ns.db.buff.delay + 0.01)
            wow.systemMessage("No player named 'Bob' is currently playing.")
            wow.systemMessage("No player named 'Bob' is currently playing.")
            settle()
            wow.advance(5)
            wow.keyDown()
            assert.are.equal(1, #wow.sentTo("SAY"))
        end)

        it("a whisper waiting longer than the /say limit still goes out", function()
            stranger()
            wow.state.lockdown = true
            wow.gainBuff({ sourceUnit = "target", name = "Fort" })
            wow.advance(ns.db.buff.delay + ns.BuffTracker.SAY_MAX_AGE + 30)
            wow.state.lockdown = false
            wow.advance(ns.ChatQueue.RETRY_DELAY)
            assert.are.same({ "Thank you for the Fort, Bob!" }, wow.sentTo("WHISPER"))
        end)

        it("drops the /say fallback for a failed whisper after the /say limit, and logs it", function()
            ns.db.debug = true
            stranger()
            wow.gainBuff({ sourceUnit = "target", name = "Fort" })
            wow.advance(ns.db.buff.delay + 0.01)
            wow.systemMessage("No player named 'Bob' is currently playing.")
            wow.advance(ns.db.buff.delay + ns.BuffTracker.SAY_MAX_AGE + ns.ChatQueue.RETRY_DELAY + 1)
            wow.keyDown()
            assert.are.equal(0, #wow.sentTo("SAY"))
            assert.is_true(logHas("dropped buff for whisper failed:Bob: waited too long ("
                .. ns.BuffTracker.SAY_MAX_AGE .. "s)"))
        end)

        it("still batches several buffs into one whisper", function()
            stranger()
            wow.gainBuff({ sourceUnit = "target", name = "A" })
            wow.gainBuff({ sourceUnit = "target", name = "B" })
            wow.advance(ns.db.buff.delay + 0.01)
            assert.are.equal(1, #wow.sent)
            assert.are.equal("Thank you for the A and B, Bob!", wow.sent[1].text)
        end)

        it("whispers a caster found from a recent cast", function()
            buffer("mouseover", "Carol")
            wow.fire("UNIT_SPELLCAST_SUCCEEDED", "mouseover", "g", 1459)
            wow.gainBuff({ name = "Arcane Intellect", spellId = 1459 })
            wow.advance(ns.db.buff.delay + 0.01)
            assert.are.equal("Carol", wow.sent[1].target)
        end)
    end)

    describe("aura data the event can't show directly", function()
        it("re-reads a locked aura from the game by its ID", function()
            stranger()
            wow.state.queryOverride = {
                [77] = { auraInstanceID = 77, isHelpful = true, name = "Fort", sourceUnit = "target",
                         isFromPlayerOrPlayerPet = true },
            }
            wow.fire("UNIT_AURA", "player", { addedAuras = { wow.lockedAura(77) } })
            settle()
            assert.are.same({ "Thank you for the Fort, Bob!" }, wow.sentTo("SAY"))
        end)

        it("skips a locked aura when the game's query is restricted too", function()
            stranger()
            wow.state.aurasRestricted = true
            wow.fire("UNIT_AURA", "player", { addedAuras = { wow.lockedAura(77) } })
            settle()
            assert.are.equal(0, #wow.sent)
        end)

        it("finds a new buff in a full update", function()
            stranger()
            wow.state.playerAuras = {
                { auraInstanceID = 501, isHelpful = true, name = "Fort", sourceUnit = "target",
                  isFromPlayerOrPlayerPet = true },
            }
            wow.fire("UNIT_AURA", "player", { isFullUpdate = true })
            settle()
            assert.are.same({ "Thank you for the Fort, Bob!" }, wow.sentTo("SAY"))
        end)

        it("doesn't re-thank buffs you already had when a full update comes (zoning)", function()
            stranger()
            wow.gainBuff({ sourceUnit = "target", name = "Fort" })
            settle()
            wow.advance(ns.db.buff.repeatCooldown + 1)
            wow.fire("UNIT_AURA", "player", { isFullUpdate = true })
            settle()
            assert.are.equal(1, #wow.sent)
        end)

        it("doesn't thank buffs you logged in with once the grace period ends", function()
            ns = wow.boot({ noGrace = true })
            ns.db.buff.messages = { "Thank you for the {buff}, {name}!" }
            stranger()
            wow.state.playerAuras = {
                { auraInstanceID = 9, isHelpful = true, name = "Old", sourceUnit = "target",
                  isFromPlayerOrPlayerPet = true },
            }
            wow.fire("UNIT_AURA", "player", { isFullUpdate = true })
            wow.advance(ns.Announcer.LOGIN_GRACE + 1)
            wow.fire("UNIT_AURA", "player", { isFullUpdate = true })
            settle()
            assert.are.equal(0, #wow.sent)
        end)

        it("forgets removed buffs so a recast is seen as new", function()
            stranger()
            -- No duration: the same aura comes back later and must not look stale.
            local aura = wow.gainBuff({ sourceUnit = "target", name = "Fort", duration = 0, expirationTime = 0 })
            settle()
            wow.state.playerAuras = {}
            wow.fire("UNIT_AURA", "player", { removedAuraInstanceIDs = { aura.auraInstanceID } })
            wow.advance(ns.db.buff.repeatCooldown + 1)
            wow.state.playerAuras = { aura }
            wow.fire("UNIT_AURA", "player", { isFullUpdate = true })
            settle()
            assert.are.equal(2, #wow.sent)
        end)

        it("copes with a client that has no aura query API", function()
            _G.C_UnitAuras = nil
            stranger()
            wow.fire("UNIT_AURA", "player", { isFullUpdate = true })
            wow.fire("UNIT_AURA", "player", { addedAuras = { wow.lockedAura(5) } })
            wow.gainBuff({ sourceUnit = "target", name = "Fort" })
            settle()
            assert.are.equal(1, #wow.sent)
        end)
    end)

    describe("restricted (secret) data", function()
        it("skips a fully secret payload", function()
            wow.fire("UNIT_AURA", "player", wow.secret({}))
            settle()
            assert.are.equal(0, #wow.sent)
        end)

        it("skips auras whose caster or flags are secret", function()
            stranger()
            wow.gainBuff({ sourceUnit = wow.secret("target"), name = "A" })
            wow.gainBuff({ sourceUnit = "target", name = "B", isHelpful = wow.secret(true) })
            settle()
            assert.are.equal(0, #wow.sent)
        end)

        it("skips casters whose unit info is secret", function()
            wow.addUnit("target", { name = wow.secret("Bob") })
            wow.gainBuff({ sourceUnit = "target", name = "A" })
            settle()
            assert.are.equal(0, #wow.sent)
        end)

        it("thanks without the buff name when only the name is secret", function()
            stranger()
            wow.gainBuff({ sourceUnit = "target", name = wow.secret("A") })
            settle()
            assert.are.same({ "Thank you for the buff, Bob!" }, wow.sentTo("SAY"))
        end)

        it("ignores secret cast events", function()
            ns.db.buff.fallbackToSay = false
            buffer("mouseover", "Carol")
            wow.fire("UNIT_SPELLCAST_SUCCEEDED", "mouseover", "g", wow.secret(1459))
            wow.gainBuff({ name = "A", spellId = 1459 })
            settle()
            assert.are.equal(0, #wow.sent)
        end)
    end)

    it("never sends a message that would break chat, whatever the buff is called", function()
        stranger()
        wow.gainBuff({ sourceUnit = "target", name = "|cffff0000Evil|r|Hlink|h" .. string.rep("x", 400) })
        settle()
        assert.are.equal(1, #wow.sent)
        assert.is_nil(wow.sent[1].text:find("|"))
        assert.is_true(#wow.sent[1].text <= 255)
    end)
end)
