-- Spec: #388
-- BuffTracker's "no caster unit" check and Comm's routes read IsInGroup()
-- (and Comm's IsInGuild() and IsInRaid()) through Util.ReadGameValues: an
-- answer that can't be read never errors, is never tested, and is taken
-- the pessimistic way.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local FORT = 10938 -- Power Word: Fortitude (as receipts_spec.lua)

-- The ways a yes-or-no answer can't be read.
local UNREADABLE = {
    ["a secret true"] = function() return wow.secret(true) end,
    ["a secret false"] = function() return wow.secret(false) end,
    nothing = function() return nil end,
    ["an error"] = function() error("blocked") end,
    ["a number"] = function() return 1 end,
}

local function count(ns, key)
    return ns.Diag.Counters()[key] or 0
end

local function logHas(ns, fragment)
    for _, line in ipairs(ns.db.diagLog or {}) do
        if line:find(fragment, 1, true) then return true end
    end
    return false
end

describe("BuffTracker's group check when IsInGroup() can't be read (#388)", function()
    local ns, realIsInGroup

    local function boot()
        ns = wow.boot({ db = { debug = true } })
        ns.db.buff.messages = { "Thank you for the {buff}, {name}!" }
        realIsInGroup = _G.IsInGroup
    end

    local function settle()
        wow.advance(ns.Receipts.WAIT + ns.db.buff.delay + 0.01)
        wow.keyDown()
    end

    -- A buff from a player the game doesn't name: a stranger's, or a
    -- groupmate's totem, aura or shout.
    local function unnamedBuff(name)
        wow.gainBuff({ name = name or "Arcane Intellect", spellId = 1459, isFromPlayerOrPlayerPet = true })
    end

    before_each(boot)
    after_each(function() _G.IsInGroup = realIsInGroup end)

    it("out of a group, an unnamed buff is thanked as 'friend', as before (white)", function()
        unnamedBuff()
        settle()
        assert.are.same({ "Thank you for the Arcane Intellect, friend!" }, wow.sentTo("SAY"))
        assert.are.same({}, wow.errors)
    end)

    it("in a group, an unnamed buff isn't thanked, as before (white)", function()
        wow.state.groupType = "party"
        unnamedBuff()
        settle()
        assert.are.equal(0, #wow.sent)
        assert.is_true(logHas(ns, "no caster unit, and you're in a group (could be a groupmate's totem)"))
        assert.are.same({}, wow.errors)
    end)

    it("an unreadable answer never errors and thanks nobody, in a group or out of one (black)", function()
        for answer, unreadable in pairs(UNREADABLE) do
            for _, groupType in ipairs({ false, "party", "raid" }) do
                boot()
                wow.state.groupType = groupType or nil
                _G.IsInGroup = unreadable
                unnamedBuff()
                settle()
                local where = answer .. ", " .. tostring(groupType)
                assert.are.equal(0, #wow.sent, where)
                assert.is_true(logHas(ns, "no caster unit, and the game won't say whether you're in a group"), where)
                assert.are.same({}, wow.errors, where)
                assert.are.equal(0, count(ns, "luaErrors"), where)
                _G.IsInGroup = realIsInGroup
            end
        end
    end)

    it("the client's own unreadable group (a secret) thanks nobody and logs no secret (black)", function()
        wow.state.inGroupUnreadable = true
        unnamedBuff()
        settle()
        assert.are.equal(0, #wow.sent)
        assert.are.same({}, wow.errors)
        assert.is_nil(table.concat(ns.db.diagLog, "\n"):find("<secret>", 1, true))
    end)

    -- As in a group (#138), a stranger's copy of the addon may still name
    -- them: one of our buffs with no caster unit waits for its receipt.
    it("an unreadable answer still lets a receipt name the caster, as in a group (black)", function()
        for answer, unreadable in pairs(UNREADABLE) do
            ns = wow.boot({ db = { buff = { thankStyle = "whisper", messages = { "Thanks {name}" } } } })
            _G.IsInGroup = unreadable
            wow.gainBuff({ name = "Power Word: Fortitude", spellId = FORT })
            wow.fire("CHAT_MSG_ADDON", "FriendlyFvr", "1;RECEIPT;Ann-Vale;fortitude;?", "WHISPER", "Ann-Vale",
                "", 0, 0, "", 0)
            wow.advance(ns.Receipts.WAIT + ns.db.buff.delay + 0.5)
            wow.keyDown()
            assert.are.same({ "Thanks Ann" }, wow.sentTo("WHISPER"), answer)
            assert.are.same({}, wow.errors, answer)
            _G.IsInGroup = realIsInGroup
        end
    end)

    -- Out of a group throughout: only IsInGroup()'s answer changes. A buff
    -- may be thanked only if IsInGroup() answered a plain false when it
    -- arrived; worked out from the answer the test gave, not from the code.
    it("a storm of unnamed buffs with IsInGroup() sometimes unreadable never errors, and never thanks a buff that arrived unreadable (red)", function()
        local ways = { "readable" }
        for answer in pairs(UNREADABLE) do ways[#ways + 1] = answer end
        table.sort(ways)
        local thanked, unsafeSeen = 0, 0
        for _, seed in ipairs({ 7, 388, 2026, 9001 }) do
            random.seed(seed)
            boot()
            local way = "readable"
            _G.IsInGroup = function(...)
                if way == "readable" then return realIsInGroup(...) end
                return UNREADABLE[way](...)
            end
            local unsafe, n = {}, 0
            for _ = 1, 200 do
                local roll = random.random(1, 10)
                if roll <= 3 then
                    way = ways[random.random(1, #ways)]
                elseif roll <= 7 then
                    n = n + 1
                    local name = string.format("Gift%04d", n)
                    if way ~= "readable" then
                        unsafe[name] = true
                        unsafeSeen = unsafeSeen + 1
                    end
                    unnamedBuff(name)
                elseif roll <= 9 then
                    wow.advance(random.random(1, 40))
                    wow.keyDown()
                else
                    wow.advance(ns.BuffTracker.UNKNOWN_COOLDOWN + 1)
                    wow.keyDown()
                end
            end
            settle()
            for _, text in ipairs(wow.sentTo("SAY")) do
                thanked = thanked + 1
                for name in text:gmatch("Gift%d%d%d%d") do
                    assert.is_nil(unsafe[name], "seed " .. seed .. ": thanked " .. name .. " in " .. text)
                end
            end
            assert.are.same({}, wow.errors, "seed " .. seed)
            assert.are.equal(0, count(ns, "luaErrors"), "seed " .. seed)
            _G.IsInGroup = realIsInGroup
        end
        -- Live: both kinds of buff happened, and some thanks went out.
        assert.is_true(unsafeSeen > 0)
        assert.is_true(thanked > 0)
    end)
end)

describe("Comm's routes when the game's group or guild answer can't be read (#388)", function()
    local ns
    local saved

    -- Each route, the answer that opens it, and the state that makes it
    -- open in the simulated client.
    local ROUTES = {
        { route = "PARTY", fn = "IsInGroup", groupType = "party" },
        { route = "INSTANCE_CHAT", fn = "IsInGroup", groupType = "instance" },
        { route = "RAID", fn = "IsInRaid", groupType = "raid" },
        { route = "GUILD", fn = "IsInGuild" },
    }

    local function boot(groupType)
        ns = wow.boot({ db = { debug = true } })
        wow.state.groupType = groupType
        saved = { IsInGroup = _G.IsInGroup, IsInRaid = _G.IsInRaid, IsInGuild = _G.IsInGuild }
    end

    after_each(function()
        for k, v in pairs(saved or {}) do _G[k] = v end
    end)

    it("a readable answer opens or closes each route as before (white)", function()
        for _, r in ipairs(ROUTES) do
            boot(r.groupType)
            ns.Comm.SayHello(r.route)
            assert.are.equal(1, count(ns, "commSent"), r.route .. ": open")
            if r.groupType then
                boot(nil)
                ns.Comm.SayHello(r.route)
                assert.are.equal(0, count(ns, "commSent"), r.route .. ": out of the group")
                assert.is_true(logHas(ns, "didn't send HELLO on " .. r.route .. ": not in that group any more"), r.route)
            end
            assert.are.same({}, wow.errors, r.route)
        end
        -- Each group route asks about its own kind of group: a home party
        -- doesn't open INSTANCE_CHAT, and an instance group doesn't open PARTY.
        for _, cross in ipairs({ { "INSTANCE_CHAT", "party" }, { "PARTY", "instance" } }) do
            boot(cross[2])
            ns.Comm.SayHello(cross[1])
            assert.are.equal(0, count(ns, "commSent"), cross[1] .. " in " .. cross[2])
            -- Closed before it reaches the game, not refused by it.
            assert.are.equal(0, #wow.addonRefused, cross[1])
            assert.is_true(logHas(ns, "didn't send HELLO on " .. cross[1] .. ": not in that group any more"), cross[1])
            assert.are.same({}, wow.errors, cross[1])
        end
    end)

    it("an unreadable answer never errors and counts the route as closed (black)", function()
        for answer, unreadable in pairs(UNREADABLE) do
            for _, r in ipairs(ROUTES) do
                local where = answer .. ", " .. r.route
                boot(r.groupType)
                _G[r.fn] = unreadable
                ns.Comm.SayHello(r.route)
                assert.are.equal(0, count(ns, "commSent"), where)
                assert.are.equal(0, #wow.addonSent, where)
                assert.is_true(logHas(ns, "didn't send HELLO on " .. r.route .. ": not in that group any more"), where)
                assert.are.same({}, wow.errors, where)
                assert.are.equal(0, count(ns, "luaErrors"), where)
                _G[r.fn] = saved[r.fn]
            end
        end
    end)
end)
