-- Spec: #70
-- The raid buff split: copies of the addon in the same raid share out the
-- buffs their class has in common over the hidden channel, so two priests
-- or two paladins don't give the same buff. The split only narrows what
-- buff mode offers; incoming shares are untrusted.
local wow = require("spec.support.wow")

local FORT, SPIRIT, SHADOW = 10938, 27841, 10958
local PRAYER_FORT = 21564
local KINGS, WISDOM_1, MIGHT_1 = 20217, 19742, 19740
local INTELLECT = 10157

local PRIEST_SPELLS = { [FORT] = true, [SPIRIT] = true, [SHADOW] = true }
local PALADIN_SPELLS = { [KINGS] = true, [WISDOM_1] = true, [MIGHT_1] = true }

-- Which buff key a spell ID is.
local KEY_OF = { [FORT] = "fortitude", [PRAYER_FORT] = "fortitude", [SPIRIT] = "spirit", [SHADOW] = "shadow",
    [KINGS] = "kings", [WISDOM_1] = "wisdom", [MIGHT_1] = "might" }

local function count(ns, key)
    return ns.Diag.Counters()[key] or 0
end

-- A table as text, keys sorted, to compare saved settings.
local function dump(v)
    if type(v) ~= "table" then return tostring(v) end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local out = {}
    for _, k in ipairs(keys) do out[#out + 1] = tostring(k) .. "=" .. dump(v[k]) end
    return "{" .. table.concat(out, ",") .. "}"
end

-- The live client's raid unit for a full name.
local function unitOf(full)
    for token, u in pairs(wow.state.units) do
        if u.id == full and token:find("^raid") then return u end
    end
end

local function keysOf(share)
    local out = {}
    for key in pairs(share or {}) do out[#out + 1] = key end
    table.sort(out)
    return table.concat(out, ",")
end

describe("The raid buff split (#70)", function()
    local clients, net, others

    -- A raid. players: the copies of the addon, each
    -- { name, surname, class, known, order = buff order, db = extra buffBack };
    -- extra: raid members without the addon, { full name, class }.
    local function raid(players, extra)
        clients, others = {}, extra or {}
        for _, p in ipairs(players) do
            local buffBack = { buffOrder = p.order }
            for k, v in pairs(p.db or {}) do buffBack[k] = v end
            local c = wow.newClient({ name = p.name, surname = p.surname, buffDefaults = p.buffDefaults,
                db = { buffBack = buffBack },
                before = function(state)
                    state.class = p.class
                    state.knownSpells = {}
                    for id in pairs(p.known) do state.knownSpells[id] = true end
                end })
            c.class, c.group = p.class, p.group
            -- Copies take part while buff mode is on (the owner's decision on #70).
            if not p.buffModeOff then c.ns.BuffMode.Set(true) end
            clients[#clients + 1] = c
        end
        net = wow.network(clients)
    end

    -- Put every client in the raid with the others (and the extras), and
    -- let the roster settle and the shares go round.
    local function form(members)
        members = members or clients
        for _, c in ipairs(clients) do
            wow.use(c)
            local names, classes = {}, {}
            local inIt = false
            for _, m in ipairs(members) do
                if m == c then inIt = true end
            end
            if inIt then
                local groups = {}
                for _, m in ipairs(members) do
                    if m ~= c then
                        names[#names + 1] = m.full
                        classes[#names], groups[#names] = m.class, m.group
                    end
                end
                for _, o in ipairs(others) do
                    names[#names + 1] = o[1]
                    classes[#names], groups[#names] = o[2], o[3]
                end
                wow.setGroup("raid", names)
                for i, class in ipairs(classes) do
                    wow.state.units["raid" .. i].class = class
                    wow.state.units["raid" .. i].subgroup = groups[i]
                end
            else
                wow.setGroup(nil)
            end
            wow.fire("GROUP_ROSTER_UPDATE")
        end
        wow.advanceAll(net, 30, 0.5)
    end

    local function share(c)
        wow.use(c)
        local mine = c.ns.RaidSplit.Current()
        return mine and keysOf(mine) or nil
    end

    -- Every offer buff mode would make now (GroupBuffs' clickable list).
    local function offers(c)
        wow.use(c)
        local list = {}
        c.ns.GroupBuffs.Next(list)
        return list
    end

    describe("three priests (white)", function()
        before_each(function()
            local order = { "fortitude", "spirit", "shadow" }
            raid({
                { name = "Ann", surname = "Vale", class = "PRIEST", known = PRIEST_SPELLS, order = order },
                { name = "Bob", surname = "Lake", class = "PRIEST", known = PRIEST_SPELLS, order = order },
                { name = "Cid", surname = "Rock", class = "PRIEST", known = PRIEST_SPELLS, order = order },
            }, { { "Tor-Axe", "WARRIOR" }, { "Mia-Fire", "MAGE" } })
            form()
        end)

        it("three simulated priests in a raid reach the same split: Fortitude, Spirit, Shadow Protection", function()
            assert.equal("fortitude", share(clients[1]))
            assert.equal("spirit", share(clients[2]))
            assert.equal("shadow", share(clients[3]))
            -- Every copy works out the same whole split.
            local seen
            for _, c in ipairs(clients) do
                wow.use(c)
                local _, all = c.ns.RaidSplit.Current()
                local text = {}
                for name, s in pairs(all) do text[#text + 1] = name .. "=" .. keysOf(s) end
                table.sort(text)
                text = table.concat(text, ";")
                seen = seen or text
                assert.equal(seen, text)
            end
        end)

        it("each is offered only their own share", function()
            for _, c in ipairs(clients) do
                local list = offers(c)
                assert.is_true(#list > 0)
                local mine = share(c)
                for _, offer in ipairs(list) do assert.equal(mine, offer.buff.key) end
            end
        end)

        it("each one's presses cast only their own share, and together the raid gets all three", function()
            local got = {} -- [member] = { [key] = true }
            for _, c in ipairs(clients) do
                wow.use(c)
                c.ns.BuffMode.Set(true)
                for _ = 1, 10 do
                    local before = #wow.casts
                    wow.pressKey("MOUSEWHEELUP")
                    local cast = wow.casts[before + 1]
                    if not cast then break end
                    assert.equal(share(c), KEY_OF[cast.id])
                    got[cast.target] = got[cast.target] or {}
                    got[cast.target][KEY_OF[cast.id]] = true
                    -- Let it show on them, as the game does a moment later.
                    for token, u in pairs(wow.state.units) do
                        if u.id == cast.target and token:find("^raid") then
                            u.auras, u.auraSources = u.auras or {}, u.auraSources or {}
                            u.auras[#u.auras + 1] = cast.id
                            u.auraSources[#u.auras] = "player"
                        end
                    end
                    wow.advance(2)
                end
            end
            -- Divine Spirit is for mana users only.
            assert.equal("fortitude,shadow", keysOf(got["Tor-Axe"]))
            assert.equal("fortitude,shadow,spirit", keysOf(got["Mia-Fire"]))
        end)

        it("the group version goes with the share: only the Fortitude priest is offered Prayer of Fortitude", function()
            for _, c in ipairs(clients) do
                wow.use(c)
                wow.state.knownSpells[PRAYER_FORT] = true
                wow.state.items[wow.ITEM.sacredCandle] = 5
                c.ns.BuffData.SpellsChanged()
            end
            for _, c in ipairs(clients) do
                for _, offer in ipairs(offers(c)) do
                    if offer.cast then assert.equal(clients[1], c) end
                    assert.equal(share(c), offer.buff.key)
                end
            end
        end)

        it("/friendly status names the split", function()
            wow.use(clients[2])
            assert.equal("raid split: Your share: Divine Spirit; Ann Vale has Power Word: Fortitude, "
                .. "Cid Rock has Shadow Protection", clients[2].ns.RaidSplit.StatusLine())
        end)
    end)

    describe("two paladins (white)", function()
        before_each(function()
            local order = { "kings", "wisdom", "might" }
            raid({
                { name = "Ann", surname = "Vale", class = "PALADIN", known = PALADIN_SPELLS, order = order,
                    buffDefaults = true },
                { name = "Bob", surname = "Lake", class = "PALADIN", known = PALADIN_SPELLS, order = order,
                    buffDefaults = true },
            }, { { "Tor-Axe", "WARRIOR" }, { "Rex-Knife", "ROGUE" }, { "Mia-Fire", "MAGE" },
                { "Pia-Light", "PRIEST" }, { "Dru-Oak", "DRUID" } })
            form()
        end)

        -- The Blessing each member would get from c: buff mode's list
        -- holds each member once, with the buff it would give them first,
        -- and a paladin keeps one Blessing on each player.
        local function blessings(c)
            local out = {}
            for _, offer in ipairs(offers(c)) do out[offer.name] = offer.buff.key end
            return out
        end

        it("two paladins split Blessings so each member gets two different Blessings", function()
            assert.equal("kings", share(clients[1]))
            assert.equal("might,wisdom", share(clients[2]))
            local fromAnn, fromBob = blessings(clients[1]), blessings(clients[2])
            for _, o in ipairs(others) do
                local name = o[1]
                assert.truthy(fromAnn[name], name)
                assert.truthy(fromBob[name], name)
                assert.are_not.equal(fromAnn[name], fromBob[name])
            end
            -- Might to the physical classes, Wisdom to the casters (#219's defaults).
            assert.equal("might", fromBob["Tor-Axe"])
            assert.equal("wisdom", fromBob["Mia-Fire"])
        end)

        it("My Blessings in this raid is filled in by the split and shown", function()
            wow.use(clients[2])
            local R = clients[2].ns.BuffRules
            assert.is_false(R.CoversInRaid(clients[2].ns.BuffData.ByKey("kings")))
            assert.is_true(R.CoversInRaid(clients[2].ns.BuffData.ByKey("wisdom")))
            assert.is_true(R.CoversInRaid(clients[2].ns.BuffData.ByKey("might")))
        end)

        it("a hand override is announced and the others re-split around it", function()
            wow.use(clients[1])
            _G.SlashCmdList.FRIENDLYFOREVER("blessings might")
            assert.equal("might", share(clients[1]))
            wow.advanceAll(net, 15, 0.5)
            assert.equal("kings,wisdom", share(clients[2]))
            -- Back to the split.
            wow.use(clients[1])
            _G.SlashCmdList.FRIENDLYFOREVER("blessings all")
            wow.advanceAll(net, 15, 0.5)
            assert.equal("kings", share(clients[1]))
            assert.equal("might,wisdom", share(clients[2]))
        end)
    end)

    describe("two paladins: setting every Blessing by hand (white)", function()
        before_each(function()
            local order = { "kings", "wisdom", "might" }
            raid({
                { name = "Ann", surname = "Vale", class = "PALADIN", known = PALADIN_SPELLS, order = order },
                { name = "Bob", surname = "Lake", class = "PALADIN", known = PALADIN_SPELLS, order = order },
            }, { { "Tor-Axe", "WARRIOR" } })
            form()
        end)

        it("in a split, choosing all three by hand keeps all three, and the other becomes the backup", function()
            wow.use(clients[1])
            _G.SlashCmdList.FRIENDLYFOREVER("blessings")
            assert.truthy(wow.printed[#wow.printed - 1]:find("your share of the raid split", 1, true))
            _G.SlashCmdList.FRIENDLYFOREVER("blessings kings wisdom might")
            assert.is_true(clients[1].ns.BuffRules.RaidBlessingsChosen())
            assert.equal("kings,might,wisdom", share(clients[1]))
            wow.advanceAll(net, 15, 0.5)
            assert.equal("", share(clients[2]))
            -- "all" stops choosing: back to the split.
            wow.use(clients[1])
            _G.SlashCmdList.FRIENDLYFOREVER("blessings all")
            assert.is_false(clients[1].ns.BuffRules.RaidBlessingsChosen())
            wow.advanceAll(net, 15, 0.5)
            assert.equal("kings", share(clients[1]))
            assert.equal("might,wisdom", share(clients[2]))
        end)
    end)

    describe("players who leave (white)", function()
        before_each(function()
            local order = { "fortitude", "spirit", "shadow" }
            raid({
                { name = "Ann", surname = "Vale", class = "PRIEST", known = PRIEST_SPELLS, order = order },
                { name = "Bob", surname = "Lake", class = "PRIEST", known = PRIEST_SPELLS, order = order },
                { name = "Cid", surname = "Rock", class = "PRIEST", known = PRIEST_SPELLS, order = order },
            }, { { "Tor-Axe", "WARRIOR" } })
            form()
        end)

        it("a player who leaves has their share picked up by the others", function()
            form({ clients[2], clients[3] })
            assert.equal("fortitude", share(clients[2]))
            assert.equal("shadow,spirit", share(clients[3]))
            assert.is_nil(share(clients[1])) -- out of the raid: no split
        end)

        it("a leaver is forgotten, and a copy that leaves forgets the raid", function()
            form({ clients[2], clients[3] })
            wow.use(clients[2])
            assert.equal(1, clients[2].ns.RaidSplit.PeerCount())
            wow.use(clients[1])
            assert.equal(0, clients[1].ns.RaidSplit.PeerCount())
        end)

        it("out of the raid there's no split, even before the roster update arrives", function()
            wow.use(clients[1])
            wow.setGroup("party", { "Bob-Lake" })
            wow.advance(0.1) -- the next frame
            assert.is_nil(share(clients[1]))
        end)

        it("a copy that reloads in the raid asks, and hears everyone's share again", function()
            -- Ann's /reload: a fresh copy of the addon, still in the raid.
            local old = clients[1]
            local fresh = wow.newClient({ name = "Ann", surname = "Vale", db = { buffBack = { buffOrder =
                { "fortitude", "spirit", "shadow" } } }, before = function(state)
                    state.class = "PRIEST"
                    state.knownSpells = { [FORT] = true, [SPIRIT] = true, [SHADOW] = true }
                end })
            fresh.class = "PRIEST"
            fresh.ns.BuffMode.Set(true)
            wow.setGroup("raid", { "Bob-Lake", "Cid-Rock", "Tor-Axe" })
            for i, class in ipairs({ "PRIEST", "PRIEST", "WARRIOR" }) do wow.state.units["raid" .. i].class = class end
            wow.state.networked = true
            net.clients[1], net.seen[fresh] = fresh, 0
            clients[1] = fresh
            -- The game says nothing about the roster after a reload; only
            -- PLAYER_ENTERING_WORLD.
            wow.reloadInPlace()
            wow.advanceAll(net, 30, 0.5)
            assert.equal("fortitude", share(fresh))
            assert.equal("spirit", share(clients[2]))
            assert.equal("shadow", share(clients[3]))
            assert.equal(2, fresh.ns.RaidSplit.PeerCount())
            assert.is_not_nil(old)
        end)

        it("a player who goes offline has their share picked up by the others", function()
            for _, c in ipairs({ clients[2], clients[3] }) do
                wow.use(c)
                unitOf("Ann-Vale").offline = true
                wow.advance(0.1) -- the next frame
            end
            assert.equal("fortitude", share(clients[2]))
            assert.equal("shadow,spirit", share(clients[3]))
        end)
    end)

    describe("no other copy of your class (black)", function()
        it("with no other copy of your class, everything is offered as before", function()
            raid({
                { name = "Ann", surname = "Vale", class = "PRIEST", known = PRIEST_SPELLS,
                    order = { "fortitude", "spirit", "shadow" } },
                { name = "Mia", surname = "Fire", class = "MAGE", known = { [INTELLECT] = true } },
            }, { { "Pia-Light", "PRIEST" }, { "Tor-Axe", "WARRIOR" } })
            form()
            assert.is_nil(share(clients[1]))
            wow.use(clients[1])
            for _, buff in ipairs(clients[1].ns.BuffData.Mine()) do
                assert.is_true(clients[1].ns.BuffRules.CoversInRaid(buff))
            end
            assert.is_nil(share(clients[2]))
        end)

        it("in a party, two priests don't split", function()
            local order = { "fortitude", "spirit", "shadow" }
            raid({
                { name = "Ann", surname = "Vale", class = "PRIEST", known = PRIEST_SPELLS, order = order },
                { name = "Bob", surname = "Lake", class = "PRIEST", known = PRIEST_SPELLS, order = order },
            })
            for _, c in ipairs(clients) do
                wow.use(c)
                wow.setGroup("party", { c == clients[1] and "Bob-Lake" or "Ann-Vale" })
                wow.fire("GROUP_ROSTER_UPDATE")
            end
            wow.advanceAll(net, 30, 0.5)
            assert.is_nil(share(clients[1]))
            assert.is_nil(share(clients[2]))
            wow.use(clients[1])
            assert.truthy(clients[1].ns.RaidSplit.StatusLine():find("not in a raid", 1, true))
            for _, msg in ipairs(wow.addonSent) do assert.is_nil(msg.text:find(";SHARE;", 1, true)) end
        end)
    end)

    describe("classes with nothing to share (black)", function()
        it("two warriors don't split: Battle Shout reaches only your party", function()
            local BATTLE_SHOUT = 25289
            raid({
                { name = "Ann", surname = "Vale", class = "WARRIOR", known = { [BATTLE_SHOUT] = true } },
                { name = "Bob", surname = "Lake", class = "WARRIOR", known = { [BATTLE_SHOUT] = true } },
            })
            form()
            assert.is_nil(share(clients[1]))
            wow.use(clients[1])
            local shout = clients[1].ns.BuffData.ByKey("battleshout")
            assert.is_true(clients[1].ns.BuffRules.CoversInRaid(shout))
            assert.truthy(clients[1].ns.RaidSplit.StatusLine():find("no buffs to share", 1, true))
            for _, msg in ipairs(wow.addonSent) do assert.is_nil(msg.text:find(";SHARE;", 1, true)) end
        end)
    end)

    describe("untrusted shares (black)", function()
        local me

        before_each(function()
            raid({ { name = "Ann", surname = "Vale", class = "PRIEST", known = PRIEST_SPELLS,
                order = { "fortitude", "spirit", "shadow" } } },
                { { "Pia-Light", "PRIEST" }, { "Tor-Axe", "WARRIOR" }, { "Off-Line", "PRIEST" } })
            form()
            me = clients[1]
            wow.use(me)
            unitOf("Off-Line").offline = true
        end)

        local function hear(text, sender, route)
            wow.fire("CHAT_MSG_ADDON", "FriendlyFvr", text, route or "RAID", sender or "Pia-Light", "", 0, 0, "", 0)
        end

        it("a well-formed share from a priest in the raid splits (the control)", function()
            hear("1;SHARE;Pia-Light;fortitude,spirit,shadow;-;0")
            -- Ann picks first, Pia then picks twice (the second round runs backwards).
            assert.equal("fortitude", share(me))
        end)

        it("spoofed, malformed, out-of-raid, wrong-class, offline and flooding shares change nothing", function()
            local bad = {
                { "1;SHARE;Pia-Light;fortitude,spirit;-;0", "Tor-Axe" },         -- about someone else
                { "1;SHARE;Tor-Axe;fortitude,spirit;-;0", "Tor-Axe" },           -- a warrior
                { "1;SHARE;Zed-Away;fortitude;-;0", "Zed-Away" },                 -- not in the raid
                { "1;SHARE;Off-Line;fortitude;-;0", "Off-Line" },                 -- offline
                { "1;SHARE;Pia-Light;fortitude;-", "Pia-Light" },                  -- a field missing
                { "1;SHARE;Pia-Light;fortitude;-;0;x", "Pia-Light" },            -- one too many
                { "1;SHARE;Pia-Light;fortitude;-;2", "Pia-Light" },              -- not a flag
                { "1;SHARE;Pia-Light;Fort itude;-;0", "Pia-Light" },               -- not a key
                { "1;SHARE;Pia-Light;a,b,c,d,e,f,g,h,i;-;0", "Pia-Light" },        -- too many keys
                { "1;SHARE;Pia-Light;fortitude;-;0", "Pia-Light", "WHISPER" },     -- the wrong route
                { "1;SHARE;Pia-Light;fortitude;-;0", "Pia-Light", "GUILD" },
                { "2;SHARE;Pia-Light;fortitude;-;0", "Pia-Light" },                -- another version
                { string.rep("x", 300), "Pia-Light" },                           -- oversized
            }
            for _, case in ipairs(bad) do hear(case[1], case[2], case[3]) end
            assert.is_nil(share(me))
            -- The warrior, the stranger and the offline priest passed the
            -- channel's checks and were ignored here; the rest never got here.
            -- Only the stranger is counted: another class's shares are everyday.
            assert.equal(1, count(me.ns, "splitIgnored"))
            assert.equal(1, count(me.ns, "commSpoofed"))
            assert.equal(0, me.ns.RaidSplit.PeerCount())
        end)

        it("keys that aren't the class's buffs are dropped", function()
            hear("1;SHARE;Pia-Light;intellect,might,battleshout,nonsense;kings;0")
            -- Pia is heard, but gives nothing of ours: no split, we keep everything.
            assert.equal(1, me.ns.RaidSplit.PeerCount())
            assert.is_nil(share(me))
        end)

        it("only Blessings a player says they give count as set by hand", function()
            -- A priest can't set Fortitude by hand: Pia drafts like anyone.
            hear("1;SHARE;Pia-Light;fortitude,spirit,shadow;fortitude;0")
            assert.equal("fortitude", share(me))
        end)

        it("a share that asks for ours is answered, at most once per MIN_GAP however often it asks", function()
            local function shares()
                local n = 0
                for _, msg in ipairs(wow.addonSent) do
                    if msg.text:find(";SHARE;", 1, true) then n = n + 1 end
                end
                return n
            end
            wow.advance(30)
            local before = shares()
            hear("1;SHARE;Pia-Light;spirit;-;1")
            wow.advance(me.ns.RaidSplit.SETTLE)
            assert.equal(before + 1, shares())
            -- Asked every second for a minute (the channel lets one a second through).
            for _ = 1, 60 do
                hear("1;SHARE;Pia-Light;spirit;-;1")
                wow.advance(1)
            end
            wow.advance(me.ns.RaidSplit.MIN_GAP)
            assert.is_true(shares() - before <= 1 + 60 / me.ns.RaidSplit.MIN_GAP + 1)
            -- Ours doesn't ask back: it isn't our first.
            assert.truthy(wow.addonSent[#wow.addonSent].text:find(";0$"))
        end)

        it("a player can only announce themselves, and once each: a flood doesn't grow the split", function()
            for i = 1, 200 do hear("1;SHARE;Pia-Light;" .. (i % 2 == 0 and "spirit" or "shadow") .. ";-;0") end
            wow.advance(60)
            hear("1;SHARE;Pia-Light;spirit;-;0")
            assert.equal(1, me.ns.RaidSplit.PeerCount())
            assert.equal("fortitude,shadow", share(me))
            assert.is_true(count(me.ns, "commFlood") > 0)
        end)

        it("a share heard before the clock went back no longer counts", function()
            hear("1;SHARE;Pia-Light;fortitude,spirit,shadow;-;0")
            assert.equal("fortitude", share(me))
            wow.now = wow.now - 100
            assert.is_nil(share(me))
        end)

        it("a share never casts, sends chat or changes saved settings", function()
            local casts, chat = #wow.casts, #wow.sent
            local saved = dump(_G.FriendlyForeverDB)
            hear("1;SHARE;Pia-Light;fortitude,spirit,shadow;-;0")
            wow.advance(30)
            assert.equal(casts, #wow.casts)
            assert.equal(chat, #wow.sent)
            assert.equal(saved, dump(_G.FriendlyForeverDB))
        end)
    end)

    describe("the owner's decisions: when a share goes back (white)", function()
        local function shares()
            local function sharesSent(c)
                wow.use(c)
                local n = 0
                for _, msg in ipairs(wow.addonSent) do
                    if msg.text:find(";SHARE;", 1, true) then n = n + 1 end
                end
                return n
            end
            return sharesSent
        end

        before_each(function()
            local order = { "fortitude", "spirit", "shadow" }
            raid({
                { name = "Ann", surname = "Vale", class = "PRIEST", known = PRIEST_SPELLS, order = order },
                { name = "Bob", surname = "Lake", class = "PRIEST", known = PRIEST_SPELLS, order = order },
                { name = "Cid", surname = "Rock", class = "PRIEST", known = PRIEST_SPELLS, order = order },
            }, { { "Tor-Axe", "WARRIOR" } })
            form()
        end)

        it("copies say their share again every minute, so the split holds as long as they're there", function()
            local sharesSent = shares()
            local before = sharesSent(clients[1])
            wow.advanceAll(net, 600, 1)
            assert.equal("fortitude", share(clients[1]))
            assert.equal("spirit", share(clients[2]))
            assert.equal("shadow", share(clients[3]))
            local sent = sharesSent(clients[1]) - before
            assert.is_true(sent >= 9 and sent <= 11, tostring(sent))
        end)

        it("a player who goes quiet (no word for 3 minutes) has their share picked up by the others", function()
            net.lose = function(_, sender) return sender == clients[1] end
            wow.advanceAll(net, 150, 1)
            assert.equal("spirit", share(clients[2])) -- not yet: 3 minutes
            wow.advanceAll(net, 60, 1)
            assert.equal("fortitude", share(clients[2]))
            assert.equal("shadow,spirit", share(clients[3]))
        end)

        it("after a long fight that blocked every message, the split is back within seconds", function()
            for _, c in ipairs(clients) do
                wow.use(c)
                wow.enterCombat()
            end
            net.lose = function() return true end
            wow.advanceAll(net, 300, 1)
            net.lose = nil
            assert.is_nil(share(clients[2])) -- everyone has gone quiet
            for _, c in ipairs(clients) do
                wow.use(c)
                wow.leaveCombat()
            end
            wow.advanceAll(net, 5, 0.5)
            assert.equal("fortitude", share(clients[1]))
            assert.equal("spirit", share(clients[2]))
            assert.equal("shadow", share(clients[3]))
        end)

        it("a copy takes part while buff mode is on, and for 5 minutes after it goes off", function()
            wow.use(clients[1])
            clients[1].ns.BuffMode.Set(false)
            wow.advanceAll(net, 240, 1)
            assert.equal("fortitude", share(clients[1]))
            assert.equal("spirit", share(clients[2]))
            wow.advanceAll(net, 130, 1)
            assert.is_nil(share(clients[1]))
            assert.equal("fortitude", share(clients[2]))
            assert.equal("shadow,spirit", share(clients[3]))
            -- Saying "not taking part" once is enough.
            local sharesSent = shares()
            local before = sharesSent(clients[1])
            wow.advanceAll(net, 300, 1)
            assert.equal(before, sharesSent(clients[1]))
            -- Buff mode on again: back in at once.
            wow.use(clients[1])
            clients[1].ns.BuffMode.Set(true)
            wow.advanceAll(net, 15, 0.5)
            assert.equal("fortitude", share(clients[1]))
            assert.equal("spirit", share(clients[2]))
            assert.equal("shadow", share(clients[3]))
        end)

        it("switched off, a copy is offered everything, says nothing, and the others pick up its share", function()
            wow.use(clients[1])
            local w = clients[1].ns.Options.widgets
            wow.run(w.tabs.buffBack, "OnClick")
            assert.is_true(w.raidSplit:IsShown())
            assert.is_true(w.raidSplit:GetChecked())
            w.raidSplit:SetChecked(false)
            wow.run(w.raidSplit, "OnClick")
            assert.is_false(clients[1].ns.db.buffBack.raidSplit)
            assert.is_nil(share(clients[1]))
            local sharesSent = shares()
            local before = sharesSent(clients[1])
            wow.advanceAll(net, 240, 1)
            assert.equal(before, sharesSent(clients[1]))
            assert.equal("fortitude", share(clients[2]))
            assert.equal("shadow,spirit", share(clients[3]))
            wow.use(clients[1])
            assert.truthy(clients[1].ns.RaidSplit.StatusLine():find("switched off", 1, true))
        end)
    end)

    describe("the off switch's setting", function()
        it("is on by default, and a damaged value reads as on (black)", function()
            local ns = wow.boot()
            assert.is_true(ns.Config.DEFAULTS.buffBack.raidSplit)
            assert.is_true(ns.db.buffBack.raidSplit)
            for _, bad in ipairs({ "yes", 5, {}, 0 }) do
                ns = wow.boot({ db = { buffBack = { raidSplit = bad } } })
                assert.is_true(ns.db.buffBack.raidSplit, tostring(bad))
            end
            ns = wow.boot({ db = { buffBack = { raidSplit = false } } })
            assert.is_false(ns.db.buffBack.raidSplit)
            ns.db.buffBack.raidSplit = "damaged mid-session"
            assert.is_true(ns.RaidSplit.Enabled())
        end)

        it("is found by the options search", function()
            local ns = wow.boot({ before = function(state) state.settingsSearch = true end })
            local found = false
            for _, entry in ipairs(ns.OptionsIndex.SETTINGS) do
                if entry.name == "Share buffs with other copies in raids" then found = true end
            end
            assert.is_true(found)
        end)
    end)

    describe("more players than buffs (white)", function()
        it("two mages split the raid's groups 1-4 and 5-8, and each buffs only their own groups", function()
            raid({
                { name = "Ann", surname = "Vale", class = "MAGE", known = { [INTELLECT] = true }, group = 1 },
                { name = "Bob", surname = "Lake", class = "MAGE", known = { [INTELLECT] = true }, group = 5 },
            }, { { "Pia-Light", "PRIEST", 3 }, { "Zoe-Sage", "PRIEST", 6 }, { "Odd-Group", "PRIEST", 8 } })
            form()
            wow.use(clients[1])
            assert.equal("Your share: Arcane Intellect (groups 1-4)", clients[1].ns.RaidSplit.ShareText(false))
            local names = {}
            for _, offer in ipairs(offers(clients[1])) do names[#names + 1] = offer.name end
            assert.same({ "Pia-Light" }, names)
            names = {}
            for _, offer in ipairs(offers(clients[2])) do names[#names + 1] = offer.name end
            table.sort(names)
            assert.same({ "Odd-Group", "Zoe-Sage" }, names)
        end)

        it("a group that can't be read is offered, not left out", function()
            raid({
                { name = "Ann", surname = "Vale", class = "MAGE", known = { [INTELLECT] = true }, group = 1 },
                { name = "Bob", surname = "Lake", class = "MAGE", known = { [INTELLECT] = true }, group = 5 },
            }, { { "Pia-Light", "PRIEST", 7 } })
            form()
            wow.use(clients[1])
            unitOf("Pia-Light").secrets = { subgroup = true }
            local names = {}
            for _, offer in ipairs(offers(clients[1])) do names[#names + 1] = offer.name end
            assert.same({ "Pia-Light" }, names)
        end)

        it("a fourth priest shares the buff fewest hold: Fortitude, by groups", function()
            local order = { "fortitude", "spirit", "shadow" }
            raid({
                { name = "Ann", surname = "Vale", class = "PRIEST", known = PRIEST_SPELLS, order = order },
                { name = "Bob", surname = "Lake", class = "PRIEST", known = PRIEST_SPELLS, order = order },
                { name = "Cid", surname = "Rock", class = "PRIEST", known = PRIEST_SPELLS, order = order },
                { name = "Dan", surname = "Moss", class = "PRIEST", known = PRIEST_SPELLS, order = order },
            })
            form()
            wow.use(clients[1])
            assert.equal("Your share: Power Word: Fortitude (groups 1-4); Bob Lake has Divine Spirit, "
                .. "Cid Rock has Shadow Protection, Dan Moss has Power Word: Fortitude (groups 5-8)",
                clients[1].ns.RaidSplit.ShareText(true))
        end)

        it("a fifth priest takes the buff the fewest hold: Divine Spirit, as Fortitude already has two", function()
            local order = { "fortitude", "spirit", "shadow" }
            local p = {}
            for i, n in ipairs({ { "Ann", "Vale" }, { "Bob", "Lake" }, { "Cid", "Rock" }, { "Dan", "Moss" },
                { "Eve", "Hill" } }) do
                p[i] = { name = n[1], surname = n[2], class = "PRIEST", known = PRIEST_SPELLS, order = order }
            end
            raid(p)
            form()
            wow.use(clients[5])
            assert.equal("Your share: Divine Spirit (groups 5-8)", clients[5].ns.RaidSplit.ShareText(false))
            wow.use(clients[2])
            assert.equal("Your share: Divine Spirit (groups 1-4)", clients[2].ns.RaidSplit.ShareText(false))
        end)

        it("a fourth paladin is a backup, offered no Blessing, until a share opens", function()
            local order = { "kings", "wisdom", "might" }
            local p = {}
            for i, n in ipairs({ { "Ann", "Vale" }, { "Bob", "Lake" }, { "Cid", "Rock" }, { "Dan", "Moss" } }) do
                p[i] = { name = n[1], surname = n[2], class = "PALADIN", known = PALADIN_SPELLS, order = order }
            end
            raid(p, { { "Tor-Axe", "WARRIOR" } })
            form()
            assert.equal("", share(clients[4]))
            assert.equal(0, #offers(clients[4]))
            wow.use(clients[4])
            assert.equal("Your share: none, you're a backup", clients[4].ns.RaidSplit.ShareText(false))
            form({ clients[2], clients[3], clients[4] })
            assert.equal("might", share(clients[4]))
        end)
    end)

    describe("where it says so (white)", function()
        before_each(function()
            local order = { "fortitude", "spirit", "shadow" }
            raid({
                { name = "Ann", surname = "Vale", class = "PRIEST", known = PRIEST_SPELLS, order = order },
                { name = "Bob", surname = "Lake", class = "PRIEST", known = PRIEST_SPELLS, order = order },
            }, { { "Tor-Axe", "WARRIOR" } })
            form()
        end)

        local function tooltip(c)
            wow.use(c)
            wow.run(c.ns.BuffButton.Frame(), "OnEnter")
            local text = {}
            for _, line in ipairs(_G.GameTooltip.lines or {}) do
                text[#text + 1] = type(line) == "table" and line.text or line
            end
            return table.concat(text, "\n")
        end

        it("the button's tooltip says your share and who has the rest; its subtitle is unchanged", function()
            local tip = tooltip(clients[2])
            assert.truthy(tip:find("Your share: Divine Spirit, Shadow Protection; Ann Vale has Power Word: Fortitude",
                1, true), tip)
            wow.use(clients[2])
            assert.truthy(clients[2].ns.BuffButton.Frame().subtitle:GetText():find("^missing your "))
        end)

        it("the button's empty text says your share when everyone has it", function()
            wow.use(clients[1])
            for _, name in ipairs({ "Tor-Axe", "Bob-Lake" }) do
                local u = unitOf(name)
                u.auras, u.auraSources = { FORT }, { "player" }
            end
            clients[1].ns.BuffButton.Refresh()
            local text = clients[1].ns.BuffButton.Frame().subtitle:GetText()
            assert.truthy(text:find("Your share: Power Word: Fortitude", 1, true), text)
        end)
    end)

    describe("chaos (red)", function()
        it("a storm of joins, leaves, offline players, reorders, overrides and dropped messages settles on one split",
            function()
                local random = require("spec.support.random")
                local ORDERS = {
                    { "fortitude", "spirit", "shadow" }, { "spirit", "shadow", "fortitude" },
                    { "shadow", "fortitude", "spirit" }, { "kings", "wisdom", "might" },
                    { "might", "kings", "wisdom" }, { "wisdom", "might", "kings" },
                }
                for _, seed in ipairs({ 1, 7, 42, 2026 }) do
                    random.seed(seed)
                    local class = seed % 2 == 0 and "PALADIN" or "PRIEST"
                    local known = class == "PALADIN" and PALADIN_SPELLS or PRIEST_SPELLS
                    local base = class == "PALADIN" and 3 or 0
                    local players = {}
                    for i, n in ipairs({ { "Ann", "Vale" }, { "Bob", "Lake" }, { "Cid", "Rock" }, { "Dan", "Moss" } }) do
                        players[i] = { name = n[1], surname = n[2], class = class, known = known,
                            order = ORDERS[base + 1 + (i % 3)], group = 1 + (i % 8) }
                    end
                    raid(players, { { "Tor-Axe", "WARRIOR", 2 } })
                    local inRaid = { true, true, true, true }
                    local function members()
                        local out = {}
                        for i, c in ipairs(clients) do
                            if inRaid[i] then out[#out + 1] = c end
                        end
                        return out
                    end
                    form(members())
                    for _ = 1, 40 do
                        local roll = random.random(1, 6)
                        local i = random.random(1, #clients)
                        local c = clients[i]
                        if roll == 1 then
                            inRaid[i] = not inRaid[i]
                            form(members())
                        elseif roll == 2 then
                            wow.use(c)
                            local order = ORDERS[base + random.random(1, 3)]
                            c.ns.db.buffBack.buffOrder = { order[1], order[2], order[3] }
                            c.ns.BuffButton.Refresh()
                        elseif roll == 3 and class == "PALADIN" and inRaid[i] then
                            wow.use(c)
                            local pick = ({ "kings", "wisdom", "might" })[random.random(1, 3)]
                            _G.SlashCmdList.FRIENDLYFOREVER(random.random(1, 2) == 1 and ("blessings " .. pick)
                                or "blessings all")
                        elseif roll == 4 then
                            net.lose = function() return random.random(1, 3) == 1 end
                        else
                            net.lose = nil
                        end
                        wow.advanceAll(net, random.random(1, 20), 1)
                    end
                    -- Calm: no more losses, then a few minutes for the
                    -- heartbeats to carry everything.
                    net.lose = nil
                    wow.advanceAll(net, 4 * 60, 1)
                    local seen
                    local holder = {}
                    local splitting = 0
                    for i, c in ipairs(clients) do
                        if inRaid[i] then
                            wow.use(c)
                            local mine, all = c.ns.RaidSplit.Current()
                            local text
                            if mine then
                                local parts = {}
                                for name, sh in pairs(all) do parts[#parts + 1] = name .. "=" .. keysOf(sh) end
                                table.sort(parts)
                                text = table.concat(parts, ";")
                            end
                            -- Worked out independently: who holds each key whole.
                            if mine then
                                for key, v in pairs(mine) do
                                    local fixed = c.ns.BuffRules.RaidBlessingsChosen()
                                    if v == true and not fixed then
                                        assert.is_nil(holder[key], "seed " .. seed .. ": two copies hold " .. key)
                                        holder[key] = c.full
                                    end
                                end
                            end
                            if text then splitting = splitting + 1 end
                            seen = seen or text
                            assert.equal(seen, text, "seed " .. seed)
                        end
                    end
                    -- Everyone in the raid takes part in the split, or nobody does.
                    local inIt = #members()
                    assert.equal(inIt >= 2 and inIt or 0, splitting, "seed " .. seed)
                    for _, c in ipairs(clients) do
                        wow.use(c)
                        assert.same({}, wow.errors)
                    end
                end
            end)
    end)

    describe("an update that adds RaidSplit.lua (black)", function()
        it("asks for a restart, not erroring, after only a /reload", function()
            wow.reset()
            local loaded = {}
            local _, files = wow.parseToc()
            for _, file in ipairs(files) do
                if file ~= "RaidSplit.lua" then assert(loadfile(wow.ROOT .. file))(wow.ADDON_NAME, loaded) end
            end
            wow.fire("ADDON_LOADED", wow.ADDON_NAME)
            wow.fire("PLAYER_ENTERING_WORLD", true, false)
            wow.setGroup("raid", { "Pia-Light" })
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.fire("CHAT_MSG_ADDON", "FriendlyFvr", "1;SHARE;Pia-Light;fortitude;-;0", "RAID", "Pia-Light", "", 0, 0, "", 0)
            wow.advance(20)
            assert.are.same({}, wow.errors)
            assert.are.equal(0, #wow.casts)
            assert.truthy(table.concat(wow.printed, "\n"):find("Restart the game (not /reload)", 1, true))
        end)
    end)
end)
